defmodule ReqManagedAgents.Session2 do
  @moduledoc false
  # Unified provider-agnostic agent loop. One GenServer drives any Provider in either transport
  # mode; the mode only changes how a turn's events are ACQUIRED (poll vs collect-from-stream).
  use GenServer
  alias ReqManagedAgents.{Provider, Tools}

  @spec run(module(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(provider, opts) do
    case GenServer.start_link(__MODULE__, {provider, Keyword.put(opts, :caller, self())}) do
      {:ok, pid} ->
        timeout = opts[:timeout] || 600_000
        receive do
          {:session_result, ^pid, result} -> result
        after
          timeout -> GenServer.stop(pid, :normal); {:error, :timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Start a long-lived session. Unlike run/2, it stays alive after a terminal for follow-ups."
  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(provider, opts) do
    GenServer.start_link(__MODULE__, {provider, opts}, name: opts[:name])
  end

  @doc "Return a child_spec for a live session."
  def child_spec({provider, opts}) do
    %{id: opts[:name] || __MODULE__, start: {__MODULE__, :start_link, [provider, opts]}, restart: :transient}
  end

  @doc "Send a follow-up user message into a running live session."
  @spec message(pid(), String.t()) :: :ok
  def message(pid, text), do: GenServer.cast(pid, {:message, text})

  @impl true
  def init({provider, opts}) do
    case provider.open(opts, self()) do
      {:ok, conn} ->
        state = %{
          provider: provider, mode: provider.mode(), conn: conn, opts: opts,
          handler: Keyword.fetch!(opts, :handler), context: opts[:context],
          caller: opts[:caller], notify: opts[:notify], meta: opts[:telemetry_metadata] || %{},
          ref: Map.get(conn, :ref), kicked_off: false, seen: MapSet.new(), reconnect_attempts: 0,
          events: [], turn_events: [], turns: 0, max_turns: opts[:max_turns] || 50
        }
        {:ok, state, {:continue, :maybe_kickoff}}

      {:error, reason} ->
        {:stop, {:open_failed, reason}}
    end
  end

  # request_response kicks off immediately; streaming waits for the stream's :connected.
  @impl true
  def handle_continue(:maybe_kickoff, %{mode: :request_response} = s), do: kickoff(s)
  def handle_continue(:maybe_kickoff, s), do: {:noreply, s}

  @impl true
  def handle_info({:managed_agents, ref, :connected}, %{ref: ref, kicked_off: false} = s), do: kickoff(s)
  def handle_info({:managed_agents, ref, :connected}, %{ref: ref} = s), do: {:noreply, s}

  def handle_info({:managed_agents, ref, {:event, ev}}, %{ref: ref} = s) do
    id = ev["id"]

    if is_binary(id) and MapSet.member?(s.seen, id) do
      # Already processed (re-delivered after a reconnect) — skip.
      {:noreply, s}
    else
      s = %{s | seen: if(is_binary(id), do: MapSet.put(s.seen, id), else: s.seen)}
      forward_raw(s, ev)
      s = %{s | turn_events: s.turn_events ++ [ev]}
      if s.provider.turn_boundary?(ev), do: handle_turn(s, s.turn_events), else: {:noreply, s}
    end
  end

  def handle_info({:managed_agents, ref, :done}, %{ref: ref} = s), do: {:noreply, s}

  # A LIVE streaming session (no synchronous caller) reconnects-with-consolidation on a stream
  # drop; a synchronous run/2 surfaces the error instead.
  def handle_info({:managed_agents, ref, {:error, _reason}}, %{ref: ref, caller: nil} = s) do
    Process.send_after(self(), :reconnect, backoff_ms(s))
    {:noreply, %{s | reconnect_attempts: s.reconnect_attempts + 1}}
  end

  def handle_info({:managed_agents, ref, {:error, reason}}, %{ref: ref} = s), do: stop_error(s, reason)

  def handle_info(:reconnect, s) do
    case s.provider.reconnect(s.conn, self(), s.seen) do
      {:ok, conn, pending, seen} ->
        s = %{s | conn: conn, ref: Map.get(conn, :ref), seen: seen, turn_events: [], reconnect_attempts: 0}
        if pending == [], do: {:noreply, s}, else: redrive(s, pending)

      {:error, _reason} ->
        Process.send_after(self(), :reconnect, backoff_ms(s))
        {:noreply, %{s | reconnect_attempts: s.reconnect_attempts + 1}}
    end
  end

  def handle_info({:turn, {:ok, events, conn}}, s) do
    Enum.each(events, &forward_raw(s, &1))
    handle_turn(%{s | conn: conn}, events)
  end

  def handle_info({:turn, {:error, reason}}, s), do: stop_error(s, reason)
  def handle_info(_other, s), do: {:noreply, s}

  @impl true
  def handle_cast({:message, text}, s), do: drive(s, s.provider.user_input(text))

  defp kickoff(s), do: drive(%{s | kicked_off: true}, s.provider.kickoff_input(s.opts))

  # ── acquire a turn (the ONLY mode-specific step) ──────────────────────────────
  defp drive(%{mode: :request_response} = s, input) do
    parent = self()
    %{provider: p, conn: c} = s
    Task.start_link(fn -> send(parent, {:turn, p.poll_turn(c, input)}) end)
    {:noreply, s}
  end

  defp drive(%{mode: :streaming} = s, input) do
    case s.provider.push_input(s.conn, input) do
      :ok -> {:noreply, %{s | turn_events: []}}
      {:error, reason} -> stop_error(s, reason)
    end
  end

  # ── shared per-turn handling ──────────────────────────────────────────────────
  defp handle_turn(s, turn_events) do
    s = %{s | events: s.events ++ turn_events, turns: s.turns + 1}
    outcome = s.provider.normalize(turn_events)

    cond do
      s.turns > s.max_turns ->
        stop_error(s, {:max_turns_exceeded, s.max_turns})

      outcome.terminal == :requires_action ->
        results = run_tools(outcome.custom_tool_uses, s)
        drive(s, s.provider.resume_input(outcome.custom_tool_uses, results))

      true ->
        finish(s, outcome.terminal, outcome.stop_reason)
    end
  end

  defp run_tools(custom_tool_uses, s) do
    Enum.map(custom_tool_uses, fn %{id: id, name: name, input: input} ->
      wire = Tools.run(s.handler, id, name, input, s.context, s.meta)
      Provider.result_of(id, wire)
    end)
  end

  # Re-run unanswered tool calls recovered on reconnect, then resume the loop.
  defp redrive(s, pending) do
    results = run_tools(pending, s)
    drive(s, s.provider.resume_input(pending, results))
  end

  defp backoff_ms(%{reconnect_attempts: n}), do: min(500 * Integer.pow(2, min(n, 7)), :timer.minutes(60))

  defp finish(s, terminal, stop_reason) do
    :telemetry.execute([:req_managed_agents, :session, :terminal], %{}, Map.put(s.meta, :terminal, terminal))
    notify(s, terminal)
    reply(s, {:ok, %{terminal: terminal, stop_reason: stop_reason, events: s.events}})
  end

  defp stop_error(s, reason), do: reply(s, {:error, reason})

  # A synchronous run/2 caller gets the result and the GenServer stops; a live session
  # (no caller) stays alive after a non-error terminal to accept follow-up messages.
  defp reply(%{caller: caller} = s, result) when is_pid(caller) do
    send(caller, {:session_result, self(), result})
    {:stop, :normal, s}
  end

  defp reply(s, {:error, _}), do: {:stop, :normal, s}
  defp reply(s, {:ok, _}), do: {:noreply, s}

  defp forward_raw(%{handler: h, context: ctx}, ev) when is_atom(h) and h != nil do
    if function_exported?(h, :handle_event, 2), do: h.handle_event(ev, ctx)
    :ok
  end

  defp forward_raw(_s, _ev), do: :ok

  defp notify(%{notify: pid}, terminal) when is_pid(pid), do: send(pid, {:managed_agents_session, terminal})
  defp notify(_s, _terminal), do: :ok
end
