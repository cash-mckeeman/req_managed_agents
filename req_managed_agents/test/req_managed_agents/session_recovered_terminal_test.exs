defmodule ReqManagedAgents.SessionRecoveredTerminalTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.{Client, Session, SessionInfo, SessionResult, Usage}
  alias ReqManagedAgents.Evidence.{Options, Recorder}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents

  defmodule Handler do
    def handle_tool(_, _, _), do: {:ok, "unused"}
    def handle_event(event, owner, info), do: send(owner, {:event, event, info})
  end

  for replay? <- [false, true] do
    @replay replay?
    test "recovered terminal completes the dropped turn once (stream replay: #{@replay})" do
      recovered_terminal(@replay)
    end
  end

  test "initial resume sends the new prompt without completing from historical terminal" do
    resumed_history("new prompt")
  end

  test "initial resume without a prompt parks instead of completing historical terminal" do
    resumed_history(nil)
  end

  defp resumed_history(prompt) do
    owner = self()

    old_terminal = %{
      "id" => "old-terminal",
      "type" => "session.status_idle",
      "stop_reason" => %{"type" => "end_turn"}
    }

    new_terminal = %{old_terminal | "id" => "new-terminal"}
    {:ok, transport} = start_supervised({Agent, fn -> nil end})

    adapter = fn request ->
      body =
        case {request.method, request.url.path} do
          {:get, "/v1/sessions/session/events"} ->
            %{"data" => [old_terminal], "has_more" => false}

          {:get, "/v1/sessions/session/events/stream"} ->
            resume_stream(transport, owner)

          {:post, "/v1/sessions/session/events"} ->
            send(owner, {:prompt_posted, request.body})
            # Wait for the test to release the terminal, so an old completion cannot pass.
            %{"data" => []}
        end

      {request, Req.Response.new(status: 200, body: body)}
    end

    client = Client.new(api_key: "test", req_options: [adapter: adapter, retry: false])

    {:ok, session} =
      Session.start_link(ClaudeManagedAgents,
        client: client,
        session_id: "session",
        prompt: prompt,
        handler: Handler,
        context: owner,
        notify: owner
      )

    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
    assert_receive :resume_stream_open, 2000
    assert_resume_prompt(prompt)

    refute_receive {:managed_agents_session, _}
    refute_receive {:event, ^old_terminal, _}
    stream = Agent.get(transport, & &1)
    send_sse(stream, new_terminal)

    assert_receive {:managed_agents_session,
                    %SessionResult{terminal: :end_turn, events: [^new_terminal]}},
                   1000

    GenServer.stop(session)
  end

  defp resume_stream(transport, owner) do
    stream = {self(), make_ref()}
    Agent.update(transport, fn _ -> stream end)
    send(owner, :resume_stream_open)
    async_response(stream)
  end

  defp assert_resume_prompt(nil), do: refute_receive({:prompt_posted, _})

  defp assert_resume_prompt("new prompt") do
    assert_receive {:prompt_posted, body}, 2000

    assert Jason.decode!(body) == %{
             "events" => [
               %{
                 "type" => "user.message",
                 "content" => [%{"type" => "text", "text" => "new prompt"}]
               }
             ]
           }
  end

  defp recovered_terminal(replay?) do
    owner = self()

    message = %{
      "id" => "message",
      "type" => "agent.message",
      "content" => [%{"type" => "text", "text" => "hello"}]
    }

    usage = %{
      "id" => "usage",
      "type" => "span.model_request_end",
      "model_usage" => %{
        "input_tokens" => 7,
        "output_tokens" => 3,
        "cache_read_input_tokens" => 3,
        "cache_creation_input_tokens" => 2
      }
    }

    terminal = %{
      "id" => "terminal",
      "type" => "session.status_idle",
      "stop_reason" => %{"type" => "end_turn"}
    }

    {:ok, transport} = start_supervised({Agent, fn -> %{streams: 0, posts: 0, stream: nil} end})
    {:ok, recorder} = Recorder.start_link(%Options{content: :retain})
    on_exit(fn -> if Process.alive?(recorder), do: GenServer.stop(recorder) end)

    adapter = fn request ->
      body = dropped_response(request, transport, [message, usage, terminal], replay?, owner)
      {request, Req.Response.new(status: 200, body: body)}
    end

    client = Client.new(api_key: "test", req_options: [adapter: adapter, retry: false])

    {:ok, session} =
      Session.start_link(ClaudeManagedAgents,
        client: client,
        agent_id: "agent",
        environment_id: "environment",
        prompt: "go",
        handler: Handler,
        context: owner,
        notify: owner,
        evidence_recorder: recorder
      )

    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    assert_receive {:event, ^message, %SessionInfo{session_id: "session"}}, 2000
    assert_receive :reconnected, 2000

    assert_receive {:managed_agents_session,
                    %SessionResult{
                      terminal: :end_turn,
                      session_id: "session",
                      events: events,
                      text: "hello",
                      usage: %Usage{
                        input_tokens: 7,
                        output_tokens: 3,
                        cache_read_input_tokens: 3,
                        cache_creation_input_tokens: 2,
                        input_token_basis: :uncached,
                        complete?: true
                      }
                    }},
                   1000

    assert Enum.map(events, & &1["id"]) == ["message", "usage", "terminal"]
    assert_receive {:event, ^terminal, _}
    refute_receive {:event, ^terminal, _}
    refute_receive {:event, ^message, _}
    refute_receive {:managed_agents_session, _}
    assert Agent.get(transport, &Map.take(&1, [:streams, :posts])) == %{streams: 2, posts: 1}

    :sys.get_state(session)
    assert {:ok, capture} = Recorder.snapshot(recorder)

    attempts =
      Enum.filter(capture.records, &(&1.kind == :local and &1.payload.type == :attempt_finished))

    assert Enum.map(attempts, & &1.payload.result) == [:error, :ok]
    assert Enum.uniq(Enum.map(attempts, & &1.attempt_id)) |> length() == 2

    assert [%{payload: %{result: :ok}}] =
             Enum.filter(
               capture.records,
               &(&1.kind == :local and &1.payload.type == :invocation_finished)
             )

    historical = Enum.filter(capture.records, &(&1.source_id == "history"))
    assert Enum.map(historical, & &1.native_id) == ["message", "usage", "terminal"]
    assert Enum.all?(historical, &(&1.attempt_id == nil and &1.invocation_id == nil))

    unless replay? do
      refute Enum.any?(
               capture.records,
               &(&1.source_id != "history" and &1.native_id == "terminal")
             )
    end

    GenServer.stop(session)
  end

  defp dropped_response(request, transport, events, replay?, owner) do
    case {request.method, request.url.path} do
      {:post, "/v1/sessions"} ->
        %{"id" => "session"}

      {:get, "/v1/sessions/session/events"} ->
        %{"data" => events, "has_more" => false}

      {:get, "/v1/sessions/session/events/stream"} ->
        stream = {self(), make_ref()}

        n =
          Agent.get_and_update(transport, fn state ->
            {state.streams + 1, %{state | streams: state.streams + 1, stream: stream}}
          end)

        reconnect_stream(n, stream, List.last(events), replay?, owner)
        async_response(stream)

      {:post, "/v1/sessions/session/events"} ->
        stream =
          Agent.get_and_update(transport, fn state ->
            {state.stream, %{state | posts: state.posts + 1}}
          end)

        Enum.each(Enum.drop(events, -1), &send_sse(stream, &1))
        {pid, ref} = stream
        send(pid, {ref, {:error, :closed}})
        %{"data" => []}
    end
  end

  defp reconnect_stream(2, stream, terminal, replay?, owner) do
    if replay?, do: send_sse(stream, terminal)
    send(owner, :reconnected)
  end

  defp reconnect_stream(_, _, _, _, _), do: :ok

  defp async_response({pid, ref}) do
    %Req.Response.Async{
      pid: pid,
      ref: ref,
      stream_fun: fn
        _, {_, {:error, reason}} -> {:error, reason}
        _, {_, part} -> {:ok, [part]}
      end,
      cancel_fun: fn _ -> :ok end
    }
  end

  defp send_sse({pid, ref}, event),
    do: send(pid, {ref, {:data, "data: " <> Jason.encode!(event) <> "\n\n"}})
end
