defmodule ReqManagedAgents.SessionRecoveredTerminalTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Evidence.{Options, Recorder}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents
  alias ReqManagedAgents.{Client, Session, SessionInfo, SessionResult}

  defmodule Handler do
    def handle_tool(_, _, _), do: {:ok, "unused"}
    def handle_event(event, owner, info), do: send(owner, {:event, event, info})
  end

  for replay? <- [false, true] do
    @replay replay?
    test "recovered terminal completes the dropped turn once (stream replay: #{@replay})" do
      owner = self()
      replay? = @replay
      message = %{"id" => "message", "type" => "agent.message", "content" => [%{"type" => "text", "text" => "hello"}]}
      terminal = %{"id" => "terminal", "type" => "session.status_idle", "stop_reason" => %{"type" => "end_turn"}}
      {:ok, transport} = start_supervised({Agent, fn -> %{streams: 0, posts: 0, stream: nil} end})
      {:ok, recorder} = Recorder.start_link(%Options{content: :retain})
      on_exit(fn -> if Process.alive?(recorder), do: GenServer.stop(recorder) end)

      adapter = fn request ->
        body = case {request.method, request.url.path} do
          {:post, "/v1/sessions"} -> %{"id" => "session"}
          {:get, "/v1/sessions/session/events"} -> %{"data" => [message, terminal], "has_more" => false}
          {:get, "/v1/sessions/session/events/stream"} ->
            stream = {self(), make_ref()}
            n = Agent.get_and_update(transport, fn state ->
              {state.streams + 1, %{state | streams: state.streams + 1, stream: stream}}
            end)
            if n == 2 do
              if replay?, do: send_sse(stream, terminal)
              send(owner, :reconnected)
            end
            {_, ref} = stream
            %Req.Response.Async{pid: self(), ref: ref,
              stream_fun: fn
                _, {_, {:error, reason}} -> {:error, reason}
                _, {_, part} -> {:ok, [part]}
              end,
              cancel_fun: fn _ -> :ok end}
          {:post, "/v1/sessions/session/events"} ->
            stream = Agent.get_and_update(transport, fn state -> {state.stream, %{state | posts: state.posts + 1}} end)
            send_sse(stream, message)
            {pid, ref} = stream
            send(pid, {ref, {:error, :closed}})
            %{"data" => []}
        end
        {request, Req.Response.new(status: 200, body: body)}
      end

      client = Client.new(api_key: "test", req_options: [adapter: adapter, retry: false])
      {:ok, session} = Session.start_link(ClaudeManagedAgents,
        client: client, agent_id: "agent", environment_id: "environment", prompt: "go",
        handler: Handler, context: owner, notify: owner, evidence_recorder: recorder)
      on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

      assert_receive {:event, ^message, %SessionInfo{session_id: "session"}}, 2000
      assert_receive :reconnected, 2000
      assert_receive {:managed_agents_session, %SessionResult{terminal: :end_turn, session_id: "session", events: events, text: "hello"}}, 1000
      assert Enum.map(events, & &1["id"]) == ["message", "terminal"]
      refute_receive {:event, ^message, _}
      refute_receive {:managed_agents_session, _}
      assert Agent.get(transport, &Map.take(&1, [:streams, :posts])) == %{streams: 2, posts: 1}

      assert {:ok, capture} = Recorder.snapshot(recorder)
      attempts = Enum.filter(capture.records, &(&1.kind == :local and &1.payload.type == :attempt_finished))
      assert Enum.map(attempts, & &1.payload.result) == [:error, :ok]
      assert Enum.uniq(Enum.map(attempts, & &1.attempt_id)) |> length() == 2
      assert [%{payload: %{result: :ok}}] = Enum.filter(capture.records, &(&1.kind == :local and &1.payload.type == :invocation_finished))
      historical = Enum.filter(capture.records, &(&1.source_id == "history"))
      assert Enum.map(historical, & &1.native_id) == ["message", "terminal"]
      assert Enum.all?(historical, &(&1.attempt_id == nil and &1.invocation_id == nil))
      GenServer.stop(session)
    end
  end

  defp send_sse({pid, ref}, event), do: send(pid, {ref, {:data, "data: " <> Jason.encode!(event) <> "\n\n"}})
end
