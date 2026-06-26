defmodule ReqManagedAgents.RunToCompletion do
  @moduledoc false
  # Synchronous one-shot driver: create a bare session, open the stream inline,
  # kickoff on :connected, resolve requires_action tool calls via the Handler,
  # accumulate events, and return on the first terminal (or :timeout).
  alias ReqManagedAgents.{Client, Event, Stream, Tools}

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) do
    client = opts[:client] || Client.new()
    handler = Keyword.fetch!(opts, :handler)
    context = opts[:context]
    timeout = opts[:timeout] || 120_000

    body = %{
      agent: Keyword.fetch!(opts, :agent_id),
      environment_id: Keyword.fetch!(opts, :environment_id)
    }

    case Client.create_session(client, body) do
      {:ok, %{"id" => session_id}} ->
        ref = make_ref()
        parent = self()

        {:ok, _task} =
          Task.start_link(fn -> Stream.stream(client, session_id, parent, ref: ref) end)

        deadline = System.monotonic_time(:millisecond) + timeout

        state = %{
          client: client,
          session_id: session_id,
          handler: handler,
          context: context,
          ref: ref,
          prompt: opts[:prompt] || "Begin.",
          tool_uses: %{},
          seen: MapSet.new(),
          events: []
        }

        loop(state, deadline)

      {:error, reason} ->
        {:error, {:create_session_failed, reason}}
    end
  end

  defp loop(state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      ref = state.ref

      receive do
        {:managed_agents, ^ref, :connected} ->
          _ = Client.send_event(state.client, state.session_id, Event.user_message(state.prompt))
          loop(state, deadline)

        {:managed_agents, ^ref, {:event, event}} ->
          handle_event(state, event, deadline)

        {:managed_agents, ^ref, :done} ->
          loop(state, deadline)

        {:managed_agents, ^ref, {:error, reason}} ->
          {:error, reason}
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  defp handle_event(state, %{"id" => id} = event, deadline) do
    if MapSet.member?(state.seen, id) do
      loop(state, deadline)
    else
      do_event(
        %{state | seen: MapSet.put(state.seen, id), events: state.events ++ [event]},
        event,
        deadline
      )
    end
  end

  defp handle_event(state, event, deadline),
    do: do_event(%{state | events: state.events ++ [event]}, event, deadline)

  defp do_event(state, %{"type" => "agent.custom_tool_use", "id" => id} = ev, deadline),
    do: loop(%{state | tool_uses: Map.put(state.tool_uses, id, ev)}, deadline)

  defp do_event(state, event, deadline) do
    case Event.classify(event) do
      :requires_action ->
        ids = get_in(event, ["stop_reason", "event_ids"]) || []
        loop(resolve(state, ids), deadline)

      terminal when terminal in [:end_turn, :terminated, :error, :retries_exhausted] ->
        {:ok, %{terminal: terminal, stop_reason: event["stop_reason"], events: state.events}}

      _other ->
        loop(state, deadline)
    end
  end

  defp resolve(state, ids) do
    results =
      ids
      |> Enum.map(&{&1, state.tool_uses[&1]})
      |> Enum.filter(fn {_id, ev} -> match?(%{"type" => "agent.custom_tool_use"}, ev) end)
      |> Enum.map(fn {id, %{"name" => name, "input" => input}} ->
        Tools.run(state.handler, id, name, input, state.context)
      end)

    if results != [], do: Client.send_events(state.client, state.session_id, results)
    %{state | tool_uses: Map.drop(state.tool_uses, ids)}
  end
end
