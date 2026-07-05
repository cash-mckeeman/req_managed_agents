defmodule ReqManagedAgents.Session do
  @moduledoc """
  The one agent loop, provider- and transport-agnostic.

  A `Session` drives any `ReqManagedAgents.Provider` to completion: invoke a turn → normalize →
  run the return-of-control tools locally via the `:handler` → resume → repeat until a terminal.
  The provider's `mode/0` (`:streaming` push or `:request_response` pull) only changes how a
  turn's events are *acquired*; the loop, the result shape, and the raw-event passthrough are
  identical across providers.

  Pick a provider — `ReqManagedAgents.Providers.ClaudeManagedAgents` (streaming) or
  `ReqManagedAgents.Providers.BedrockAgentCore` (request/response) — and:

      # synchronous run-to-completion
      {:ok, %ReqManagedAgents.SessionResult{terminal: t, stop_reason: r, events: raw}} =
        ReqManagedAgents.Session.run(provider, handler: MyTools, prompt: "Hi", ...)

      # live, long-lived (stays alive after a terminal; `:notify` gets {:managed_agents_session, %ReqManagedAgents.SessionResult{}})
      {:ok, pid} = ReqManagedAgents.Session.start_link(provider, handler: MyTools, notify: self(), ...)
      ReqManagedAgents.Session.message(pid, "follow-up")

  Required opts: `:handler` (a `ReqManagedAgents.Handler` module or a 3-arity fn). Optional:
  `:context`, `:prompt`, `:outcome` (a `%ReqManagedAgents.Outcome{}` or a map with the same keys
  `%{description:, rubric:, max_iterations:}` — kicks off a
  `user.define_outcome` graded session instead of a `user.message`; mutually exclusive with
  `:prompt`, outcome wins; `{:error, :outcome_unsupported}` on providers without native support),
  `:timeout`, `:max_turns`, `:notify`, `:name`, `:telemetry_metadata`,
  `:turn_guard` (a 1-arity fun invoked after each turn's usage accumulation with
  `%{usage: %ReqManagedAgents.Usage{}, turns: n, session_id: id}`, returning `:cont` or `{:halt, reason}`;
  on halt the run stops with `{:error, {:halted, reason}}` and a `:terminated` result is
  notified — usage/turns accumulate within the current request, the same scope as `:max_turns`;
  the guard runs *before* the `max_turns` check and wins when both would trip on the same turn;
  it fires on terminal-tool re-prompt turns, whose `turns` counter keeps incrementing normally;
  guards must not raise — a raising guard crashes the session and surfaces as
  `{:error, {exception, stack}}` to `run/2` rather than producing a `{:halt, …}`),
  `:require_terminal_tool` + `:terminal_tool` + `:max_reprompts` (default 2): an `:end_turn`
  that never called `terminal_tool` is re-driven with a re-prompt; exhausted re-prompts finish
  with `stop_reason: :no_terminal_tool`. Re-prompt turns count against `:max_turns`.
  For long AgentCore runs set `:timeout` (the end-to-end run budget, default 600_000 ms)
  at or above the server-side budget — a `run/2` timeout returns `{:error, :timeout}` and
  tears down the in-flight invoke client-side (the poll task and its HTTP stream are shut
  down). The server may still run the already-received invocation to its own limit: the
  server-side `timeoutSeconds` remains the authoritative server budget.
  Transport liveness is guarded per turn by `:idle_timeout` and total
  cost by the `:timeout_seconds`/`:max_iterations`/`:max_tokens` per-invocation overrides
  (Bedrock AgentCore only).
  Provider-specific opts (e.g. `:agent_id`/`:environment_id`, `:harness_arn`/`:runtime_session_id`,
  `:session_id` to resume) are forwarded to the provider's `open/2`.
  """
  use GenServer
  require Logger
  alias ReqManagedAgents.{Provider, SessionInfo, SessionResult, Tools, TurnResult, Usage}

  @max_tool_concurrency 8

  @spec run(module(), keyword()) :: {:ok, ReqManagedAgents.SessionResult.t()} | {:error, term()}
  def run(provider, opts) do
    # start (NOT start_link) + monitor: an open/init failure or an unexpected GenServer death
    # surfaces as a value here instead of a link exit that would kill the caller.
    case GenServer.start(__MODULE__, {provider, Keyword.put(opts, :caller, self())}) do
      {:ok, pid} ->
        mref = Process.monitor(pid)
        timeout = opts[:timeout] || 600_000

        receive do
          {:session_result, ^pid, result} ->
            Process.demonitor(mref, [:flush])
            result

          {:DOWN, ^mref, :process, ^pid, reason} ->
            {:error, reason}
        after
          timeout ->
            Process.demonitor(mref, [:flush])
            GenServer.stop(pid, :normal)
            {:error, :timeout}
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
    %{
      id: opts[:name] || __MODULE__,
      start: {__MODULE__, :start_link, [provider, opts]},
      restart: :transient
    }
  end

  @doc "Send a follow-up user message into a running live session."
  @spec message(pid(), String.t()) :: :ok
  def message(pid, text), do: GenServer.cast(pid, {:message, text})

  @doc """
  Post a pre-built raw user event (e.g. `Event.tool_confirmation/2`, a mid-session
  `Event.define_outcome/3`) into a running live session. The event is pushed verbatim —
  no turn accounting or accumulator reset. Streaming providers only:
  `{:error, :unsupported}` on `:request_response` providers (their input is consumed
  by `poll_turn/2`, there is no out-of-band channel).
  """
  @spec send_event(pid(), map()) :: :ok | {:error, term()}
  def send_event(pid, %{} = event), do: GenServer.call(pid, {:send_event, event})

  @impl true
  def init({provider, opts}) do
    # Trap exits so a crash in the linked stream-consumer / poll-turn Task arrives as {:EXIT,…}
    # (driving reconnect or a surfaced error) instead of killing this process and its caller.
    Process.flag(:trap_exit, true)

    case validate_opts(provider, opts) do
      :ok -> open_session(provider, opts)
      {:error, reason} -> {:stop, reason}
    end
  end

  # The one home for start-time contract checks — later tasks add clauses here,
  # not another chain in init/1.
  defp validate_opts(provider, opts) do
    cond do
      not valid_turn_guard?(opts[:turn_guard]) ->
        {:error, {:invalid_turn_guard, opts[:turn_guard]}}

      opts[:require_terminal_tool] && not is_binary(opts[:terminal_tool]) ->
        {:error, {:invalid_opts, :terminal_tool_required}}

      opts[:outcome] != nil and not valid_outcome?(opts[:outcome]) ->
        {:error, {:invalid_opts, :outcome}}

      # AgentCore has no in-session outcome equivalent (Evaluations is trace-level,
      # out-of-session); fail at start rather than silently kicking off a user.message.
      opts[:outcome] != nil and not outcomes_supported?(provider) ->
        {:error, :outcome_unsupported}

      true ->
        :ok
    end
  end

  defp valid_outcome?(%{description: d, rubric: r}), do: is_binary(d) and is_binary(r)
  defp valid_outcome?(_), do: false

  defp outcomes_supported?(provider) do
    Code.ensure_loaded?(provider) and function_exported?(provider, :supports_outcomes?, 0) and
      provider.supports_outcomes?()
  end

  defp valid_turn_guard?(nil), do: true
  defp valid_turn_guard?(guard), do: is_function(guard, 1)

  # The former init/1 body, from `case provider.open(opts, self()) do` down, moves here
  # verbatim — state map and {:continue, …} tuple unchanged (plus the new :turn_guard key).
  defp open_session(provider, opts) do
    case provider.open(opts, self()) do
      {:ok, conn} ->
        state = %{
          provider: provider,
          delta?: exports_text_delta?(provider),
          mode: provider.mode(),
          conn: conn,
          info: build_info(provider, conn),
          opts: opts,
          handler: Keyword.fetch!(opts, :handler),
          context: opts[:context],
          caller: opts[:caller],
          notify: opts[:notify],
          meta: opts[:telemetry_metadata] || %{},
          ref: Map.get(conn, :ref),
          consumer: Map.get(conn, :consumer),
          poll_task: nil,
          kicked_off: false,
          seen: MapSet.new(),
          reconnect_attempts: 0,
          events: [],
          turn_events: [],
          live_forwarded: 0,
          turns: 0,
          max_turns: opts[:max_turns] || 50,
          custom_tool_uses: [],
          server_tool_uses: [],
          usage: %Usage{input_tokens: 0, output_tokens: 0, raw: []},
          turn_guard: opts[:turn_guard],
          enforced_terminal_tool: if(opts[:require_terminal_tool], do: opts[:terminal_tool]),
          max_reprompts: opts[:max_reprompts] || 2,
          reprompts_left: opts[:max_reprompts] || 2
        }

        {:ok, state, {:continue, if(Map.get(conn, :resume), do: :resume, else: :maybe_kickoff)}}

      # Surface the provider's error verbatim (e.g. {:create_session_failed, _}) — no extra wrapping.
      {:error, reason} ->
        {:stop, reason}
    end
  end

  # request_response kicks off immediately; streaming waits for the stream's :connected.
  @impl true
  def handle_continue(:maybe_kickoff, %{mode: :request_response} = s), do: kickoff(s)
  def handle_continue(:maybe_kickoff, s), do: {:noreply, s}

  # Resuming an existing session: consolidate (reconnect/3) instead of kicking off. Mark
  # kicked_off so the reconnected stream's :connected does not fire a spurious kickoff.
  def handle_continue(:resume, s) do
    send(self(), :reconnect)
    {:noreply, %{s | kicked_off: true}}
  end

  @impl true
  def handle_info({:managed_agents, ref, :connected}, %{ref: ref, kicked_off: false} = s),
    do: kickoff(s)

  def handle_info({:managed_agents, ref, :connected}, %{ref: ref} = s), do: {:noreply, s}

  def handle_info({:managed_agents, ref, {:event, ev}}, %{ref: ref} = s) do
    id = ev["id"]

    if is_binary(id) and MapSet.member?(s.seen, id) do
      # Already processed (re-delivered after a reconnect) — skip.
      {:noreply, s}
    else
      s = %{s | seen: if(is_binary(id), do: MapSet.put(s.seen, id), else: s.seen)}
      forward_with_delta(s, ev)
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

  def handle_info({:managed_agents, ref, {:error, reason}}, %{ref: ref} = s),
    do: stop_error(s, reason)

  def handle_info(:reconnect, s) do
    case s.provider.reconnect(s.conn, self(), s.seen) do
      {:ok, conn, pending, seen} ->
        # reconnect_attempts is NOT reset here — only a real terminal (finish/2) resets it — so a
        # connect→drop flap actually escalates the backoff instead of hammering at 500ms.
        s = %{
          s
          | conn: conn,
            info: build_info(s.provider, conn),
            ref: Map.get(conn, :ref),
            consumer: Map.get(conn, :consumer),
            seen: seen,
            turn_events: []
        }

        if pending == [], do: {:noreply, s}, else: redrive(s, pending)

      # A sync run/2 surfaces a list/reconnect failure; a live session backs off and retries.
      {:error, reason} ->
        if s.caller do
          stop_error(s, reason)
        else
          Process.send_after(self(), :reconnect, backoff_ms(s))
          {:noreply, %{s | reconnect_attempts: s.reconnect_attempts + 1}}
        end
    end
  end

  # Live event from a request_response provider mid-turn (e.g. BedrockAgentCore
  # streaming): forward to the handler and telemetry NOW; the {:turn, …} that
  # follows (FIFO from the same poll-turn task) then skips batch forwarding.
  # Handler delivery is at-least-once across retried attempts — the canonical
  # exactly-once record is TurnResult/SessionResult.events.
  def handle_info({:provider_event, ev}, s) do
    forward_with_delta(s, ev)

    :telemetry.execute(
      [:req_managed_agents, :stream, :event],
      %{},
      Map.merge(s.meta, %{type: envelope_type(ev)})
    )

    {:noreply, %{s | live_forwarded: s.live_forwarded + 1}}
  end

  def handle_info({:turn, {:ok, events, conn}}, s) do
    # Batch forwarding only when nothing was live-forwarded this turn (a live
    # provider already delivered each event as it arrived).
    if s.live_forwarded == 0, do: Enum.each(events, &forward_with_delta(s, &1))
    handle_turn(%{s | conn: conn, live_forwarded: 0, poll_task: nil}, events)
  end

  def handle_info({:turn, {:error, reason}}, s), do: stop_error(s, reason)

  # Linked-Task exits: a clean exit is fine; an abnormal consumer-task crash drives reconnect
  # (live) or surfaces an error (sync); any other linked exit (parent/supervisor) stops us.
  def handle_info({:EXIT, _pid, :normal}, s), do: {:noreply, s}

  def handle_info({:EXIT, pid, _reason}, %{consumer: pid, caller: nil} = s) do
    Process.send_after(self(), :reconnect, backoff_ms(s))
    {:noreply, %{s | reconnect_attempts: s.reconnect_attempts + 1}}
  end

  def handle_info({:EXIT, pid, reason}, %{consumer: pid} = s), do: stop_error(s, reason)
  def handle_info({:EXIT, _pid, reason}, s), do: {:stop, reason, s}

  def handle_info(_other, s), do: {:noreply, s}

  @impl true
  def handle_call({:send_event, event}, _from, %{mode: :streaming} = s),
    do: {:reply, s.provider.push_input(s.conn, [event]), s}

  def handle_call({:send_event, _event}, _from, s), do: {:reply, {:error, :unsupported}, s}

  @impl true
  # A follow-up message starts a fresh request: reset the per-request turn counter and accumulators
  # so max_turns bounds a runaway tool loop within one request, not the session's whole lifetime.
  def handle_cast({:message, text}, s),
    do: drive(reset_acc(%{s | turns: 0}), s.provider.user_input(text))

  @impl true
  # Session traps exits, so this runs on every stop — including run/2's timeout
  # stop. Linked poll/consumer tasks ignore a :normal exit signal, so an
  # in-flight AgentCore invoke (or SSE consumer) would otherwise keep its HTTP
  # stream — and server-side billing — alive after the caller got :timeout.
  def terminate(_reason, s) do
    shutdown(s.poll_task)
    shutdown(s.consumer)
  end

  # Killing an already-dead pid is a harmless no-op — no liveness check needed.
  defp shutdown(pid) when is_pid(pid), do: Process.exit(pid, :kill)
  defp shutdown(_other), do: :ok

  defp reset_acc(s),
    do: %{
      s
      | events: [],
        custom_tool_uses: [],
        server_tool_uses: [],
        reprompts_left: s.max_reprompts,
        usage: %Usage{input_tokens: 0, output_tokens: 0, raw: []}
    }

  defp kickoff(s), do: drive(%{s | kicked_off: true}, s.provider.kickoff_input(s.opts))

  # ── acquire a turn (the ONLY mode-specific step) ──────────────────────────────
  defp drive(%{mode: :request_response} = s, input) do
    parent = self()
    %{provider: p, conn: c} = s

    {:ok, task} =
      Task.start_link(fn ->
        # Convert a provider raise into a surfaced error so it can't crash the Session (and, for a
        # sync run/2, the caller) — the {:ok}|{:error} contract holds even on malformed data.
        result =
          try do
            p.poll_turn(c, input)
          rescue
            e -> {:error, {:provider_error, e}}
          end

        send(parent, {:turn, result})
      end)

    {:noreply, %{s | poll_task: task}}
  end

  defp drive(%{mode: :streaming} = s, input) do
    case s.provider.push_input(s.conn, input) do
      :ok ->
        {:noreply, %{s | turn_events: []}}

      # A sync run/2 surfaces a post failure; a live session stays alive (the message is dropped,
      # matching the old fire-and-forget POST) rather than silently dying with no notify.
      {:error, reason} ->
        if s.caller, do: stop_error(s, reason), else: {:noreply, %{s | turn_events: []}}
    end
  end

  # ── shared per-turn handling ──────────────────────────────────────────────────
  defp handle_turn(s, turn_events) do
    s = %{s | events: s.events ++ turn_events, turns: s.turns + 1, turn_events: []}
    tr = s.provider.normalize(turn_events)
    s = accumulate(s, tr)
    emit_tool_use_telemetry(s, tr.custom_tool_uses)

    # The frozen governance hook: plain data in, plain verdict out. Hosts compose
    # policy here (budget caps, grant checks); this library ships only the mechanism.
    case run_turn_guard(s) do
      :cont ->
        continue_turn(s, tr)

      {:halt, reason} ->
        notify(s, session_result(s, tr, :terminated))
        stop_error(s, {:halted, reason})
    end
  end

  defp run_turn_guard(%{turn_guard: nil}), do: :cont

  defp run_turn_guard(s) do
    s.turn_guard.(%{
      usage: s.usage,
      turns: s.turns,
      session_id: s.info.session_id
    })
  end

  defp continue_turn(s, tr) do
    cond do
      s.turns > s.max_turns ->
        notify(s, session_result(s, tr, :terminated))
        stop_error(s, {:max_turns_exceeded, s.max_turns})

      tr.terminal == :requires_action ->
        results = run_tools(tr.custom_tool_uses, s)
        drive(s, s.provider.resume_input(tr.custom_tool_uses, results))

      # Terminal-tool enforcement: an :end_turn that never called the required tool
      # re-drives with a re-prompt; re-prompt turns count against :max_turns.
      tr.terminal == :end_turn and missing_terminal_tool?(s) and s.reprompts_left > 0 ->
        input = s.provider.user_input(terminal_reprompt(s.enforced_terminal_tool))
        drive(%{s | reprompts_left: s.reprompts_left - 1}, input)

      tr.terminal == :end_turn and missing_terminal_tool?(s) ->
        finish(s, %{tr | stop_reason: :no_terminal_tool})

      true ->
        finish(s, tr)
    end
  end

  defp missing_terminal_tool?(%{enforced_terminal_tool: nil}), do: false

  defp missing_terminal_tool?(%{enforced_terminal_tool: tool} = s),
    do: not Enum.any?(s.custom_tool_uses, &(&1.name == tool))

  # Wording relocated verbatim from biai-managed-agents' Core.Runner.Directives
  # (eval-gate continuity for consumers migrating off that loop).
  defp terminal_reprompt(terminal_tool),
    do:
      "You returned a response without calling #{terminal_tool}. You MUST call " <>
        "#{terminal_tool} now to finish — produce the result via #{terminal_tool}."

  defp accumulate(s, %TurnResult{} = tr) do
    %{
      s
      | custom_tool_uses: s.custom_tool_uses ++ tr.custom_tool_uses,
        server_tool_uses: s.server_tool_uses ++ tr.server_tool_uses,
        usage: add_usage(s.usage, tr.usage)
    }
  end

  defp add_usage(acc, nil), do: acc

  defp add_usage(acc, %Usage{} = u),
    do: %Usage{
      input_tokens: acc.input_tokens + u.input_tokens,
      output_tokens: acc.output_tokens + u.output_tokens,
      raw: acc.raw ++ u.raw
    }

  # Per-turn observability + a duplicate-id regression sentinel: custom_tool_uses are unique by id by
  # construction, so a duplicate reaching here is a regression (a duplicate id in the resume makes
  # a provider reject the next turn).
  defp emit_tool_use_telemetry(s, custom_tool_uses) do
    ids = Enum.map(custom_tool_uses, & &1.id)

    :telemetry.execute(
      [:req_managed_agents, :session, :tool_uses],
      %{tool_use_count: length(ids)},
      Map.merge(s.meta, %{turn: s.turns, tool_use_ids: ids})
    )

    case ids -- Enum.uniq(ids) do
      [] ->
        :ok

      dups ->
        Logger.warning(
          "duplicate tool_use id(s) #{inspect(dups)} at turn #{s.turns} — providers reject resumes carrying duplicates"
        )
    end
  end

  defp run_tools(custom_tool_uses, s) do
    custom_tool_uses
    |> Task.async_stream(
      fn %{id: id, name: name, input: input} ->
        wire = Tools.run(s.handler, id, name, input, s.context, s.info, s.meta)
        Provider.result_of(id, wire)
      end,
      max_concurrency: @max_tool_concurrency,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.map(fn {:ok, r} -> r end)
  end

  # Re-run unanswered tool calls recovered on reconnect, then resume the loop.
  defp redrive(s, pending) do
    results = run_tools(pending, s)
    drive(s, s.provider.resume_input(pending, results))
  end

  defp backoff_ms(%{reconnect_attempts: n}),
    do: min(500 * Integer.pow(2, min(n, 7)), :timer.minutes(60))

  defp session_result(s, tr, terminal) do
    %SessionResult{
      terminal: terminal,
      stop_reason: tr.stop_reason,
      session_id: s.info.session_id,
      text: tr.text,
      custom_tool_uses: s.custom_tool_uses,
      server_tool_uses: s.server_tool_uses,
      usage: s.usage,
      turns: s.turns,
      events: s.events
    }
  end

  defp finish(s, %TurnResult{} = tr) do
    :telemetry.execute(
      [:req_managed_agents, :session, :terminal],
      %{},
      Map.put(s.meta, :terminal, tr.terminal)
    )

    result = session_result(s, tr, tr.terminal)
    notify(s, result)
    # Real terminal reached — reset the reconnect backoff for any subsequent live activity.
    reply(%{s | reconnect_attempts: 0}, {:ok, result})
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

  # A Converse-envelope event is a single-key map (%{"messageStop" => …}).
  defp envelope_type(%{} = ev), do: ev |> Map.keys() |> List.first()
  defp envelope_type(_), do: nil

  defp exports_text_delta?(provider),
    do: Code.ensure_loaded?(provider) and function_exported?(provider, :text_delta, 1)

  # Additive normalization: the synthetic delta follows the raw event through the same
  # handler path and is never accumulated into events (raw preservation).
  defp forward_with_delta(%{delta?: false} = s, ev), do: forward_raw(s, ev)

  defp forward_with_delta(s, ev) do
    forward_raw(s, ev)

    case s.provider.text_delta(ev) do
      chunk when is_binary(chunk) and chunk != "" ->
        forward_raw(s, %{"type" => "rma.text_delta", "text" => chunk})

      _ ->
        :ok
    end
  end

  defp forward_raw(%{handler: h, context: ctx, info: info}, ev) when is_atom(h) and h != nil do
    cond do
      Code.ensure_loaded?(h) and function_exported?(h, :handle_event, 3) ->
        h.handle_event(ev, ctx, info)

      function_exported?(h, :handle_event, 2) ->
        h.handle_event(ev, ctx)

      true ->
        :ok
    end

    :ok
  end

  defp forward_raw(_s, _ev), do: :ok

  # Session identity for handler callbacks: providers standardize a :session_id
  # conn key (Claude mints it at open; Bedrock echoes the caller-supplied id).
  defp build_info(provider, conn),
    do: %SessionInfo{session_id: Map.get(conn, :session_id), provider: provider}

  defp notify(%{notify: pid}, payload) when is_pid(pid),
    do: send(pid, {:managed_agents_session, payload})

  defp notify(_s, _payload), do: :ok
end
