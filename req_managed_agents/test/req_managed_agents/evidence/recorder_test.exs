defmodule ReqManagedAgents.Evidence.RecorderTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Evidence
  alias ReqManagedAgents.Evidence.{LocalRecord, Options, Recorder}
  alias ReqManagedAgents.Providers.BedrockAgentCore
  alias ReqManagedAgents.Session

  test "failed first attempt survives successful retry without changing the canonical result" do
    for live? <- [false, true] do
      baseline = retry_run(nil, live?)
      recorder = recorder(content: :retain)
      assert retry_run(recorder, live?) == baseline
      assert {:ok, capture} = Recorder.snapshot(recorder)
      starts = lifecycle(capture, :attempt_started)
      assert length(starts) == 2
      [first, second] = Enum.map(starts, & &1.attempt_id)
      refute first == second

      assert Enum.any?(
               capture.records,
               &(&1.attempt_id == first and &1.payload == delta("partial"))
             )

      assert [
               %{attempt_id: ^first, payload: %{result: :error, error_code: "early_termination"}},
               %{attempt_id: ^second, payload: %{result: :ok}}
             ] = lifecycle(capture, :attempt_finished)

      assert [%{attempt_id: ^first}] = lifecycle(capture, :retry_decided)
      assert length(Enum.filter(capture.records, &(&1.kind == :native))) == 3
      assert {:ok, _} = capture |> Evidence.to_wire() |> Evidence.from_wire()
    end
  end

  test "dead, slow and full recorders preserve provider outcomes and retries" do
    baseline = retry_run(nil, true)
    dead = recorder()
    GenServer.stop(dead)
    assert retry_run(dead, true) == baseline
    assert {:error, %{code: :recorder_unavailable}} = Recorder.snapshot(dead)

    slow = recorder(max_bytes: 12_000, timeout_ms: 5)
    :ok = Recorder.context(slow, :agentcore, "session")
    :ok = :sys.suspend(slow)
    assert retry_run(slow, true) == baseline
    assert {:ok, partial} = Recorder.snapshot(slow)
    assert Enum.any?(partial.diagnostics, &(&1.code == :capture_gap))
    assert Enum.all?(partial.sources, &(&1.status == :partial))
    :ok = :sys.resume(slow)
    assert {:ok, _} = Recorder.snapshot(slow)
  end

  test "concurrent oversized admission stays bounded before a suspended consumer drains" do
    pid = recorder(content: :retain, max_bytes: 10_485_760, timeout_ms: 5)
    Recorder.context(pid, :agentcore, "session")
    :sys.suspend(pid)
    huge = String.duplicate("x", 10_485_760)
    now = DateTime.utc_now()

    {:ok, raw} =
      Evidence.Record.new(
        %{
          id: "raw",
          source_id: "native",
          ordinal: 1,
          observed_at: now,
          kind: :native,
          payload: delta(huge)
        },
        content: :retain
      )

    assert :ok = Recorder.emit(pid, raw)
    assert {:message_queue_len, 0} = Process.info(pid, :message_queue_len)

    {:ok, local} = LocalRecord.new(%{type: :invocation_start, invocation_id: "i"})

    1..20_000
    |> Task.async_stream(fn _ -> Recorder.emit(pid, local) end, max_concurrency: 16)
    |> Stream.run()

    {:message_queue_len, queued} = Process.info(pid, :message_queue_len)
    assert queued > 0
    assert queued < 10_000
    :sys.resume(pid)
    assert {:ok, capture} = Recorder.snapshot(pid)
    assert byte_size(Jason.encode!(Evidence.to_wire(capture))) <= 10_485_760
    assert Enum.any?(capture.diagnostics, &(&1.code == :capture_gap and &1.count > 0))
  end

  test "local lifecycle validation maps input vocabulary to the versioned payload" do
    pid = recorder()
    Recorder.context(pid, :managed, "session")
    assert {:error, _} = LocalRecord.new(%{type: :transport_error, invocation_id: "i"})

    assert {:error, _} =
             LocalRecord.new(%{
               type: :tool_start,
               invocation_id: "i",
               attempt_id: "a",
               secret: "x"
             })

    {:ok, event} =
      LocalRecord.new(%{
        type: :invocation_end,
        invocation_id: "i",
        result: :error,
        error_code: "open_failed"
      })

    Recorder.emit(pid, event)
    assert {:ok, capture} = Recorder.snapshot(pid)

    assert [%{payload: %{type: :invocation_finished, error_code: "open_failed"}}] =
             capture.records
  end

  test "tool failures remain local safe evidence and do not change resumption" do
    pid = recorder(content: :retain)
    owner = self()

    invoke = fn inv ->
      case inv.messages do
        [%{"role" => "user"}] ->
          {:ok,
           [
             %{
               "contentBlockStart" => %{
                 "contentBlockIndex" => 0,
                 "start" => %{"toolUse" => %{"toolUseId" => "t1", "name" => "failing"}}
               }
             },
             %{
               "contentBlockDelta" => %{
                 "contentBlockIndex" => 0,
                 "delta" => %{"toolUse" => %{"input" => "{}"}}
               }
             },
             %{"messageStop" => %{"stopReason" => "tool_use"}}
           ]}

        [_assistant, user] ->
          send(owner, {:resumed, user})
          {:ok, [stop()]}
      end
    end

    assert {:ok, result} =
             Session.run(
               BedrockAgentCore,
               opts(invoke, pid) ++
                 [handler: fn _, _, _ -> {:error, "PRIVATE_TOOL_FAILURE"} end]
             )

    assert result.turns == 2
    assert_received {:resumed, %{"content" => [%{"toolResult" => %{"status" => "error"}}]}}
    assert {:ok, capture} = Recorder.snapshot(pid)

    assert [%{payload: %{tool_use_id: "t1", result: :error, error_code: "tool_error"}}] =
             lifecycle(capture, :tool_finished)

    refute Jason.encode!(Evidence.to_wire(capture)) =~ "PRIVATE_TOOL_FAILURE"
  end

  test "caller timeout leaves retained evidence with a gap and recorder alive" do
    pid = recorder()
    owner = self()

    invoke = fn _ ->
      send(owner, :invoking)
      Process.sleep(:infinity)
    end

    assert {:error, :timeout} =
             Session.run(BedrockAgentCore, opts(invoke, pid) ++ [timeout: 20, handler: handler()])

    assert_received :invoking
    assert Process.alive?(pid)
    assert {:ok, capture} = Recorder.snapshot(pid)
    assert Enum.any?(capture.diagnostics, &(&1.code == :capture_gap))
    assert [_] = lifecycle(capture, :attempt_started)
  end

  test "pre-open transport failure records no invented native session or activity" do
    pid = recorder(content: :retain)

    client =
      ReqManagedAgents.Client.new(
        api_key: "test",
        req_options: [
          plug: fn conn ->
            Plug.Conn.send_resp(conn, 400, "PRIVATE_TRANSPORT_FAILURE")
          end
        ]
      )

    assert {:error, _} =
             Session.run(ReqManagedAgents.Providers.ClaudeManagedAgents,
               client: client,
               agent_id: "agent",
               environment_id: "env",
               handler: handler(),
               evidence_recorder: pid
             )

    assert {:ok, capture} = Recorder.snapshot(pid)
    assert capture.session_id == nil
    assert [_] = lifecycle(capture, :attempt_started)
    assert [%{payload: %{result: :error}}] = lifecycle(capture, :attempt_finished)
    assert Enum.all?(capture.records, &(&1.kind == :local))
    refute Jason.encode!(Evidence.to_wire(capture)) =~ "PRIVATE_TRANSPORT_FAILURE"
  end

  test "Claude reconnect preserves history without attributing old activity to the retry" do
    alias ReqManagedAgents.Providers.ClaudeManagedAgents, as: Claude
    pid = recorder(content: :retain)
    evidence = Recorder.begin(pid, Claude)
    Recorder.context(pid, :managed, "session")

    past = [
      %{"id" => "old-tool", "type" => "agent.custom_tool_use", "name" => "echo", "input" => %{}}
    ]

    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__.Reconnect, fn conn ->
      case conn.request_path do
        "/v1/sessions/session/events" ->
          n = Agent.get_and_update(calls, &{&1, &1 + 1})

          if n == 0,
            do: Plug.Conn.send_resp(conn, 400, "PRIVATE_HISTORY_ERROR"),
            else: Req.Test.json(conn, %{"data" => past, "has_more" => false})

        "/v1/sessions/session/events/stream" ->
          Plug.Conn.send_resp(conn, 503, "")
      end
    end)

    client =
      ReqManagedAgents.Client.new(
        api_key: "test",
        req_options: [plug: {Req.Test, __MODULE__.Reconnect}]
      )

    {:ok, conn} =
      Claude.open([client: client, session_id: "session", evidence_context: evidence], self())

    assert {:error, _} = Claude.reconnect(conn, self(), MapSet.new())

    assert {:ok, updated, [%{id: "old-tool"}], seen} =
             Claude.reconnect(conn, self(), MapSet.new())

    assert MapSet.member?(seen, "old-tool")
    assert updated.session_id == "session"
    assert Agent.get(calls, & &1) == 2
    assert {:ok, capture} = Recorder.snapshot(pid)
    assert [first, second] = lifecycle(capture, :attempt_started)
    refute first.attempt_id == second.attempt_id
    assert [%{attempt_id: failed}] = lifecycle(capture, :attempt_finished)
    assert failed == first.attempt_id

    assert [%{invocation_id: nil, attempt_id: nil, native_id: "old-tool", source_id: "history"}] =
             Enum.filter(capture.records, &(&1.kind == :native))

    refute Jason.encode!(Evidence.to_wire(capture)) =~ "PRIVATE_HISTORY_ERROR"
  end

  test "recorder death during provider work cannot change a completed invocation" do
    pid = recorder()
    owner = self()

    task =
      Task.async(fn ->
        Session.run(
          BedrockAgentCore,
          opts(
            fn inv ->
              send(owner, {:waiting, self()})

              receive do
                :continue -> :ok
              end

              inv.on_event.(stop())
              {:ok, [stop()]}
            end,
            pid
          ) ++ [handler: handler()]
        )
      end)

    assert_receive {:waiting, worker}
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    send(worker, :continue)
    assert {:ok, %{terminal: :end_turn, turns: 1}} = Task.await(task)
    assert {:error, %{code: :recorder_unavailable}} = Recorder.snapshot(pid)
  end

  test "reattached prompt and later followup each produce one finished invocation" do
    pid = recorder()
    invoke = fn _ -> {:ok, [stop()]} end

    {:ok, session} =
      Session.start_link(
        BedrockAgentCore,
        opts(invoke, pid) ++
          [session_id: "session", prompt: "resumed", notify: self(), handler: handler()]
      )

    assert_receive {:managed_agents_session, %{turns: 1}}
    Session.message(session, "next")
    assert_receive {:managed_agents_session, %{turns: 1}}
    assert {:ok, capture} = Recorder.snapshot(pid)
    starts = lifecycle(capture, :invocation_started)
    finishes = lifecycle(capture, :invocation_finished)
    assert length(starts) == 2
    assert Enum.map(starts, & &1.invocation_id) == Enum.map(finishes, & &1.invocation_id)
    assert length(Enum.uniq_by(starts, & &1.invocation_id)) == 2
    refute Enum.any?(capture.diagnostics, &(&1.code == :capture_gap))
    GenServer.stop(session)
  end

  test "a raised pre-open transport retains safe failure evidence and original failure" do
    pid = recorder()

    client =
      ReqManagedAgents.Client.new(
        api_key: "test",
        req_options: [plug: fn _ -> raise "PRIVATE_RAISED_FAILURE" end]
      )

    assert {:error, {%RuntimeError{message: "PRIVATE_RAISED_FAILURE"}, _stack}} =
             Session.run(ReqManagedAgents.Providers.ClaudeManagedAgents,
               client: client,
               agent_id: "agent",
               environment_id: "env",
               handler: handler(),
               evidence_recorder: pid
             )

    assert {:ok, capture} = Recorder.snapshot(pid)
    assert [%{payload: %{result: :error}}] = lifecycle(capture, :attempt_finished)
    assert [%{payload: %{result: :error}}] = lifecycle(capture, :invocation_finished)
    refute Jason.encode!(Evidence.to_wire(capture)) =~ "PRIVATE_RAISED_FAILURE"
  end

  test "Claude live reconnect and followup retain attempt boundaries without redelivering history" do
    baseline = claude_run(nil)
    pid = recorder(content: :retain)
    assert claude_run(pid) == baseline
    assert {:ok, capture} = Recorder.snapshot(pid)
    starts = lifecycle(capture, :attempt_started)
    assert length(starts) == 3
    assert length(Enum.uniq_by(starts, & &1.attempt_id)) == 3

    assert [:error, :ok, :ok] ==
             Enum.map(lifecycle(capture, :attempt_finished), & &1.payload.result)

    assert length(lifecycle(capture, :invocation_started)) == 2
    assert length(lifecycle(capture, :invocation_finished)) == 2

    assert [%{native_id: "preview", attempt_id: nil}] =
             Enum.filter(capture.records, &(&1.source_id == "history"))

    live = Enum.filter(capture.records, &(&1.source_id == "native"))
    assert Enum.map(live, & &1.native_id) == ["preview", "done-1", "done-2"]
    assert Enum.map(live, & &1.attempt_id) == Enum.map(starts, & &1.attempt_id)
    refute Enum.any?(capture.diagnostics, &(&1.code == :capture_gap))
  end

  test "a recorder cannot silently combine different provider sessions" do
    pid = recorder()
    Recorder.context(pid, :managed, "first-session")
    {:ok, event} = LocalRecord.new(%{type: :invocation_end, invocation_id: "i", result: :ok})
    Recorder.emit(pid, event)
    assert {:ok, %{session_id: "first-session"}} = Recorder.snapshot(pid)
    Recorder.context(pid, :managed, "other-session")
    assert {:error, %{code: :recorder_unavailable}} = Recorder.snapshot(pid)
  end

  test "failed live Claude reconnect records the retry against that failed attempt" do
    baseline = claude_run(nil, fail_history: true)
    pid = recorder(content: :retain)
    assert claude_run(pid, fail_history: true) == baseline
    assert {:ok, capture} = Recorder.snapshot(pid)
    starts = lifecycle(capture, :attempt_started)
    assert length(starts) == 4

    assert [:error, :error, :ok, :ok] ==
             Enum.map(lifecycle(capture, :attempt_finished), & &1.payload.result)

    assert Enum.map(Enum.take(starts, 2), & &1.attempt_id) ==
             Enum.map(lifecycle(capture, :retry_decided), & &1.attempt_id)

    refute Enum.any?(capture.diagnostics, &(&1.code == :capture_gap))
  end

  test "resumed Claude prompt continues its actual reconnect attempt" do
    pid = recorder()
    claude_run(pid, resume: true)
    assert {:ok, capture} = Recorder.snapshot(pid)
    assert length(lifecycle(capture, :attempt_started)) == 3
    assert length(lifecycle(capture, :invocation_started)) == 2
    refute Enum.any?(capture.diagnostics, &(&1.code == :capture_gap))
  end

  test "synchronous Claude reconnect failure closes exactly the failed attempt" do
    pid = recorder()

    client =
      ReqManagedAgents.Client.new(
        api_key: "test",
        req_options: [plug: fn conn -> Plug.Conn.send_resp(conn, 400, "failure") end]
      )

    assert {:error, _} =
             Session.run(ReqManagedAgents.Providers.ClaudeManagedAgents,
               client: client,
               session_id: "session",
               handler: handler(),
               evidence_recorder: pid
             )

    assert {:ok, capture} = Recorder.snapshot(pid)
    assert [start] = lifecycle(capture, :attempt_started)
    assert [finish] = lifecycle(capture, :attempt_finished)
    assert start.attempt_id == finish.attempt_id
    assert [] == lifecycle(capture, :retry_decided)
  end

  test "a live Claude POST failure records failure while the session remains alive" do
    owner = self()
    pid = recorder()

    adapter = fn request ->
      response =
        case {request.method, request.url.path} do
          {:post, "/v1/sessions"} ->
            Req.Response.new(status: 200, body: %{"id" => "session"})

          {:get, "/v1/sessions/session/events/stream"} ->
            Req.Response.new(
              status: 200,
              body: %Req.Response.Async{
                pid: self(),
                ref: make_ref(),
                stream_fun: fn _, _ -> {:ok, []} end,
                cancel_fun: fn _ -> :ok end
              }
            )

          {:post, "/v1/sessions/session/events"} ->
            send(owner, :post_failed)
            Req.Response.new(status: 400, body: %{"error" => "PRIVATE_POST_ERROR"})
        end

      {request, response}
    end

    client =
      ReqManagedAgents.Client.new(api_key: "test", req_options: [adapter: adapter, retry: false])

    {:ok, session} =
      Session.start_link(ReqManagedAgents.Providers.ClaudeManagedAgents,
        client: client,
        agent_id: "agent",
        environment_id: "env",
        handler: handler(),
        evidence_recorder: pid
      )

    assert_receive :post_failed
    :sys.get_state(session)
    assert Process.alive?(session)
    assert {:ok, capture} = Recorder.snapshot(pid)
    assert [%{payload: %{result: :error}}] = lifecycle(capture, :attempt_finished)
    assert [%{payload: %{result: :error}}] = lifecycle(capture, :invocation_finished)
    assert [%{payload: %{error_code: "transport_error"}}] = lifecycle(capture, :transport_failed)
    refute Jason.encode!(Evidence.to_wire(capture)) =~ "PRIVATE_POST_ERROR"
    GenServer.stop(session)
  end

  test "local ticks use a recorder-scoped nanosecond clock" do
    pid = recorder()
    Recorder.context(pid, :managed, "session")
    {:ok, start} = LocalRecord.new(%{type: :invocation_start, invocation_id: "i"})
    {:ok, finish} = LocalRecord.new(%{type: :invocation_end, invocation_id: "i", result: :ok})
    before = System.monotonic_time(:nanosecond)
    Recorder.emit(pid, start)
    Process.sleep(2)
    Recorder.emit(pid, finish)
    after_ticks = System.monotonic_time(:nanosecond)
    assert {:ok, capture} = Recorder.snapshot(pid)
    assert [start_record, end_record] = capture.records
    assert start_record.clock == :monotonic
    assert start_record.clock_id == end_record.clock_id
    assert start_record.payload.clock_id == start_record.clock_id
    assert start_record.monotonic_ticks == start_record.payload.started_ticks
    assert end_record.monotonic_ticks == end_record.payload.ended_ticks
    assert before <= start_record.monotonic_ticks
    assert end_record.monotonic_ticks <= after_ticks

    assert System.convert_time_unit(
             end_record.monotonic_ticks - start_record.monotonic_ticks,
             :nanosecond,
             :microsecond
           ) >= 1_000
  end

  defp claude_run(recorder, opts \\ []) do
    owner = self()

    {:ok, transport} =
      Agent.start_link(fn ->
        %{stream: nil, streams: 0, posts: 0, history: 0, fail_history: opts[:fail_history]}
      end)

    preview = %{
      "id" => "preview",
      "type" => "agent.message",
      "content" => [%{"type" => "text", "text" => "partial"}]
    }

    adapter = fn request ->
      body = claude_response(request, transport, preview)

      {request,
       if(is_struct(body, Req.Response),
         do: body,
         else: Req.Response.new(status: 200, body: body)
       )}
    end

    client =
      ReqManagedAgents.Client.new(api_key: "test", req_options: [adapter: adapter, retry: false])

    {:ok, session} =
      Session.start_link(ReqManagedAgents.Providers.ClaudeManagedAgents,
        client: client,
        session_id: if(opts[:resume], do: "session"),
        prompt: if(opts[:resume], do: "resume"),
        agent_id: "agent",
        environment_id: "env",
        handler: handler(),
        notify: owner,
        evidence_recorder: recorder
      )

    assert_receive {:managed_agents_session, first}, 2000
    Session.message(session, "followup")
    assert_receive {:managed_agents_session, second}, 2000
    counts = Agent.get(transport, &Map.take(&1, [:posts, :streams, :history]))

    assert counts == %{
             posts: 2,
             streams: 2,
             history:
               1 + if(opts[:resume], do: 1, else: 0) + if(opts[:fail_history], do: 1, else: 0)
           }

    assert Enum.map(first.events, & &1["id"]) == ["done-1"]
    assert Enum.map(second.events, & &1["id"]) == ["done-2"]
    GenServer.stop(session)
    Agent.stop(transport)
    {first, second, counts}
  end

  defp claude_response(request, transport, preview) do
    case {request.method, request.url.path} do
      {:post, "/v1/sessions"} ->
        %{"id" => "session"}

      {:get, "/v1/sessions/session/events"} ->
        fail? =
          Agent.get_and_update(transport, fn state ->
            {state.fail_history && state.history == 0, %{state | history: state.history + 1}}
          end)

        if fail?,
          do: Req.Response.new(status: 400, body: %{"error" => "failure"}),
          else: %{"data" => [preview], "has_more" => false}

      {:get, "/v1/sessions/session/events/stream"} ->
        ref = make_ref()
        stream = self()

        n =
          Agent.get_and_update(transport, fn state ->
            {state.streams + 1, %{state | streams: state.streams + 1, stream: {stream, ref}}}
          end)

        if n == 2, do: send_sse({stream, ref}, claude_stop("done-1"))

        %Req.Response.Async{
          pid: self(),
          ref: ref,
          stream_fun: fn
            _, {_, {:error, reason}} -> {:error, reason}
            _, {_, part} -> {:ok, [part]}
          end,
          cancel_fun: fn _ -> :ok end
        }

      {:post, "/v1/sessions/session/events"} ->
        {n, stream} =
          Agent.get_and_update(transport, fn state ->
            {{state.posts + 1, state.stream}, %{state | posts: state.posts + 1}}
          end)

        claude_post(n, stream || await_stream(transport, 1000), preview)

        %{"data" => []}
    end
  end

  defp await_stream(transport, remaining) when remaining > 0 do
    case Agent.get(transport, & &1.stream) do
      nil ->
        Process.sleep(1)
        await_stream(transport, remaining - 1)

      stream ->
        stream
    end
  end

  defp claude_post(1, {pid, ref} = stream, preview) do
    send_sse(stream, preview)
    send(pid, {ref, {:error, :closed}})
  end

  defp claude_post(_n, stream, _preview), do: send_sse(stream, claude_stop("done-2"))

  defp claude_stop(id),
    do: %{"id" => id, "type" => "session.status_idle", "stop_reason" => %{"type" => "end_turn"}}

  defp send_sse({pid, ref}, event),
    do: send(pid, {ref, {:data, "data: " <> Jason.encode!(event) <> "\n\n"}})

  defp retry_run(pid, live?) do
    owner = self()

    invoke = fn inv ->
      n = Process.get(:invoke_number, 0) + 1
      Process.put(:invoke_number, n)
      send(owner, {:invoked, n})
      events = if n == 1, do: [delta("partial")], else: [delta("complete"), stop()]
      if live?, do: Enum.each(events, inv.on_event)
      {:ok, events}
    end

    assert {:ok, result} =
             Session.run(BedrockAgentCore, opts(invoke, pid) ++ [handler: handler()])

    assert result.text == "complete"
    assert result.events == [delta("complete"), stop()]
    assert result.turns == 1
    assert_received {:invoked, 1}
    assert_received {:invoked, 2}
    refute_received {:invoked, _}
    result
  end

  defp opts(invoke, pid),
    do: [
      harness_arn: "harness",
      runtime_session_id: "session",
      invoke_fun: invoke,
      evidence_recorder: pid
    ]

  defp handler, do: fn _, _, _ -> {:ok, "unused"} end

  defp delta(text),
    do: %{"contentBlockDelta" => %{"contentBlockIndex" => 0, "delta" => %{"text" => text}}}

  defp stop, do: %{"messageStop" => %{"stopReason" => "end_turn"}}

  defp lifecycle(capture, type),
    do: Enum.filter(capture.records, &(&1.kind == :local and &1.payload.type == type))

  defp recorder(opts \\ []) do
    {:ok, options} = Options.new(opts)
    start_supervised!({Recorder, options}, id: make_ref())
  end
end
