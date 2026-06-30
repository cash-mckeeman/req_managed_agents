defmodule ReqManagedAgents.RunToCompletion do
  @moduledoc false
  # Synchronous one-shot driver: create a bare session, open the stream inline,
  # kickoff on :connected, resolve requires_action tool calls via the Handler,
  # accumulate events, and return on the first terminal (or :timeout).
  alias ReqManagedAgents.{Client, Event, Provider, Stream, Tools}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents, as: Backend

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

        state = %{
          client: client,
          session_id: session_id,
          handler: handler,
          context: context,
          ref: ref,
          prompt: opts[:prompt] || "Begin.",
          seen: MapSet.new(),
          events: [],
          tel: opts[:telemetry_metadata] || %{}
        }

        {:ok, _task} =
          Task.start_link(fn ->
            Stream.stream(client, session_id, parent,
              ref: ref,
              telemetry_metadata: tel_meta(state)
            )
          end)

        deadline = System.monotonic_time(:millisecond) + timeout

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

  defp do_event(state, %{"type" => "session.status_idle"} = event, deadline) do
    outcome = Backend.normalize(state.events)

    case outcome.terminal do
      :requires_action ->
        loop(resolve(state, outcome.custom_tool_uses), deadline)

      terminal ->
        terminal_result(state, terminal, event["stop_reason"])
    end
  end

  defp do_event(state, %{"type" => "session.status_terminated"} = event, _deadline),
    do: terminal_result(state, :terminated, event["stop_reason"])

  defp do_event(state, %{"type" => "session.error"} = event, _deadline),
    do: terminal_result(state, :terminated, event["stop_reason"])

  defp do_event(state, _event, deadline), do: loop(state, deadline)

  defp terminal_result(state, terminal, stop_reason) do
    :telemetry.execute(
      [:req_managed_agents, :session, :terminal],
      %{},
      Map.put(tel_meta(state), :terminal, terminal)
    )

    {:ok, %{terminal: terminal, stop_reason: stop_reason, events: state.events}}
  end

  defp resolve(state, custom_tool_uses) do
    results =
      Enum.map(custom_tool_uses, fn %{id: id, name: name, input: input} ->
        wire = Tools.run(state.handler, id, name, input, state.context, tel_meta(state))
        Provider.result_of(id, wire)
      end)

    events = Backend.resume(custom_tool_uses, results)
    if events != [], do: Client.send_events(state.client, state.session_id, events)
    state
  end

  defp tel_meta(s), do: Map.put(s.tel, :session_id, s.session_id)
end
