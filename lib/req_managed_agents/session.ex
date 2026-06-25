defmodule ReqManagedAgents.Session do
  @moduledoc """
  Optional supervised GenServer that drives one Managed Agents session end to end:
  open the stream, run custom tools locally via a `ReqManagedAgents.Handler`, post
  results, and reconnect-with-consolidation on stream loss.

  Required opts: `:client` (a `ReqManagedAgents.Client`), `:agent_id`,
  `:environment_id` (required for a fresh session; not needed to resume),
  `:handler` (a module implementing `ReqManagedAgents.Handler`). Optional: `:prompt` (initial
  user message; default "Begin."), `:context` (passed to the handler), `:notify`
  (pid to receive `{:managed_agents_session, terminal_atom}`), `:session_id`
  (resume an existing session), `:name`.
  """
  use GenServer
  require Logger

  alias ReqManagedAgents.{Client, Consolidate, Event, Stream}

  defstruct [
    :client,
    :handler,
    :context,
    :notify,
    :session_id,
    :prompt,
    :stream_ref,
    :consumer,
    tool_uses: %{},
    seen_ids: MapSet.new(),
    reconnect_attempts: 0
  ]

  @max_tool_concurrency 8

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  def child_spec(opts) do
    %{
      id: opts[:name] || {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @doc "Send a follow-up user message into a running session."
  def message(pid, text), do: GenServer.cast(pid, {:user_message, text})

  @impl true
  def init(opts) do
    # Trap exits so an abnormal SSE-consumer crash arrives as an {:EXIT, ...}
    # message and drives reconnect, instead of killing this GenServer via the link.
    Process.flag(:trap_exit, true)
    client = opts[:client] || Client.new()

    state = %__MODULE__{
      client: client,
      handler: Keyword.fetch!(opts, :handler),
      context: opts[:context],
      notify: opts[:notify]
    }

    case opts[:session_id] do
      nil ->
        body = %{
          agent: Keyword.fetch!(opts, :agent_id),
          environment_id: Keyword.fetch!(opts, :environment_id)
        }

        case Client.create_session(client, body) do
          {:ok, %{"id" => session_id}} ->
            {:ok, %{state | session_id: session_id, prompt: opts[:prompt] || "Begin."},
             {:continue, :connect}}

          {:error, reason} ->
            {:stop, {:create_session_failed, reason}}
        end

      session_id ->
        {:ok, %{state | session_id: session_id}, {:continue, :reconnect}}
    end
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, start_consumer(state)}

  def handle_continue(:reconnect, state) do
    case Client.list_events(state.client, state.session_id, %{limit: 1000}) do
      {:ok, %{"data" => past}} ->
        {fresh, seen} = Consolidate.dedupe(past, state.seen_ids)
        state = %{state | seen_ids: seen}
        state = Enum.reduce(fresh, state, &stash(&2, &1))
        state = redrive_pending(state, past)
        {:noreply, start_consumer(state)}

      {:error, reason} ->
        Logger.warning("[req_managed_agents] list_events failed: #{inspect(reason)}; retrying")
        Process.send_after(self(), :do_reconnect, backoff_ms(state))
        {:noreply, %{state | reconnect_attempts: state.reconnect_attempts + 1}}
    end
  end

  @impl true
  def handle_info({:managed_agents, ref, :connected}, %{stream_ref: ref} = state) do
    state =
      case state.prompt do
        nil ->
          state

        text ->
          _ = Client.send_event(state.client, state.session_id, Event.user_message(text))
          %{state | prompt: nil}
      end

    {:noreply, state}
  end

  def handle_info({:managed_agents, ref, msg}, %{stream_ref: ref} = state) do
    {:noreply, handle_stream(msg, state)}
  end

  def handle_info({:managed_agents, _stale_ref, _msg}, state), do: {:noreply, state}

  def handle_info(:do_reconnect, state), do: {:noreply, state, {:continue, :reconnect}}

  # A normal consumer exit means the stream ended cleanly; the next step was
  # already driven by its :done/{:error,_} message, so ignore.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  # The SSE consumer Task crashed abnormally. The link would otherwise kill us
  # and bypass reconnect; instead schedule a reconnect with backoff.
  def handle_info({:EXIT, pid, reason}, %{consumer: pid} = state) do
    Logger.warning("[req_managed_agents] consumer crashed: #{inspect(reason)}; reconnecting")
    Process.send_after(self(), :do_reconnect, backoff_ms(state))
    {:noreply, %{state | reconnect_attempts: state.reconnect_attempts + 1}}
  end

  # Any other linked exit (parent/supervisor) is a real shutdown signal.
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  @impl true
  def handle_cast({:user_message, text}, state) do
    _ = Client.send_event(state.client, state.session_id, Event.user_message(text))
    {:noreply, state}
  end

  # ---- stream message handling ----------------------------------------------

  defp handle_stream({:event, event}, state), do: ingest(state, event)

  defp handle_stream(:done, state) do
    Logger.debug("[req_managed_agents] stream closed for #{state.session_id}")
    state
  end

  defp handle_stream({:error, reason}, state) do
    Logger.warning("[req_managed_agents] stream error #{inspect(reason)}; reconnecting")
    Process.send_after(self(), :do_reconnect, backoff_ms(state))
    %{state | reconnect_attempts: state.reconnect_attempts + 1}
  end

  defp ingest(state, %{"id" => id} = event) do
    if MapSet.member?(state.seen_ids, id) do
      state
    else
      do_ingest(%{state | seen_ids: MapSet.put(state.seen_ids, id)}, event)
    end
  end

  defp ingest(state, event), do: do_ingest(state, event)

  defp do_ingest(state, %{"type" => "agent.custom_tool_use"} = ev), do: stash(state, ev)

  defp do_ingest(state, event) do
    case Event.classify(event) do
      :requires_action ->
        ids = get_in(event, ["stop_reason", "event_ids"]) || []
        resolve(state, ids)

      terminal when terminal in [:end_turn, :terminated, :error, :retries_exhausted] ->
        notify(state, terminal)
        maybe_handle_event(state, event)
        %{state | reconnect_attempts: 0}

      _other ->
        maybe_handle_event(state, event)
        state
    end
  end

  defp stash(state, %{"id" => id} = ev),
    do: %{state | tool_uses: Map.put(state.tool_uses, id, ev)}

  # ---- resolve a requires_action pause --------------------------------------

  defp resolve(state, ids) do
    results =
      ids
      |> Enum.map(&{&1, state.tool_uses[&1]})
      |> Enum.filter(fn {_id, ev} -> match?(%{"type" => "agent.custom_tool_use"}, ev) end)
      |> Task.async_stream(
        fn {id, %{"name" => name, "input" => input}} ->
          run_tool(state, id, name, input)
        end,
        max_concurrency: @max_tool_concurrency,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, ev} -> ev end)

    if results != [], do: Client.send_events(state.client, state.session_id, results)

    %{state | tool_uses: Map.drop(state.tool_uses, ids)}
  end

  defp run_tool(state, id, name, input) do
    try do
      case state.handler.handle_tool_call(name, input, state.context) do
        {:ok, text} -> Event.custom_tool_result(id, to_string(text))
        {:error, text} -> Event.custom_tool_result(id, to_string(text), is_error: true)
      end
    catch
      kind, reason ->
        Event.custom_tool_result(id, "tool #{kind}: #{inspect(reason)}", is_error: true)
    end
  end

  defp redrive_pending(state, past) do
    case Consolidate.pending_requires_action(past) do
      %{"event_ids" => ids} -> resolve(state, ids)
      _ -> state
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp start_consumer(state) do
    parent = self()
    # A fresh stream_ref fences any in-flight messages from a prior consumer:
    # the {:managed_agents, stale_ref, _} clause drops them, so no kill is needed.
    ref = make_ref()
    client = state.client

    {:ok, consumer} =
      Task.start_link(fn -> Stream.stream(client, state.session_id, parent, ref: ref) end)

    %{state | consumer: consumer, stream_ref: ref}
  end

  defp notify(%{notify: nil}, _terminal), do: :ok
  defp notify(%{notify: pid}, terminal), do: send(pid, {:managed_agents_session, terminal})

  defp maybe_handle_event(state, event) do
    if function_exported?(state.handler, :handle_event, 2) do
      state.handler.handle_event(event, state.context)
    end

    state
  end

  defp backoff_ms(%{reconnect_attempts: n}) do
    (500 * Integer.pow(2, min(n, 7))) |> min(:timer.minutes(60))
  end
end
