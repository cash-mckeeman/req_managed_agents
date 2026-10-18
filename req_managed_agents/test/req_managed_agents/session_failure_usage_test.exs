defmodule ReqManagedAgents.SessionFailureUsageTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.{Session, SessionResult, Usage}
  alias ReqManagedAgents.Session.Completion
  alias ReqManagedAgents.Test.FailureProvider

  for failure <- [:transport, :crash, :timeout, :deadline, :session_death] do
    @failure failure
    test "#{failure} retains completed usage and notifies before run returns" do
      test = self()
      failure = @failure

      poll = fn
        0, _ ->
          {:ok, [turn(:requires_action)]}

        1, _ ->
          send(test, {:attempt, self()})

          receive do
            :release ->
              failure_response(failure)
          end
      end

      opts = [poll_fun: poll, test_pid: test]
      opts = failure_options(failure, opts)
      runner = run_async(FailureProvider, opts)
      assert_receive {:opened, session}, 2_000
      assert_receive {:attempt, worker}, 2_000
      worker_ref = Process.monitor(worker)
      release_failure(failure, worker, session)

      expected = expected_failure(failure)
      assert_receive {:returned, ^runner, {:error, ^expected}, result, []}, 2_000
      assert %SessionResult{} = result
      assert result.terminal == :terminated
      assert result.turns == 1
      assert result.usage.input_tokens == 12
      assert result.usage.output_tokens == 4
      assert result.usage.cache_read_input_tokens == 3
      assert result.usage.cache_creation_input_tokens == 2
      assert result.usage.complete?
      assert result.in_flight == :unknown
      assert result.stop_reason == "native-stop"
      assert result.events == [turn(:requires_action)]
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}
    end
  end

  test "first-attempt timeout retains zero observed usage without asserting no work" do
    test = self()

    poll = fn _, _ ->
      send(test, {:attempt, self()})
      receive do: (:release -> {:error, :late})
    end

    runner = run_async(FailureProvider, poll_fun: poll, timeout: 100)
    assert_receive {:attempt, _}, 2_000
    assert_receive {:returned, ^runner, {:error, :timeout}, result, []}, 2_000
    assert %SessionResult{} = result
    assert result.usage == Usage.zero()
    assert result.turns == 0
    assert result.in_flight == :unknown
  end

  for {terminal, kind, error, tokens} <- [
        {:end_turn, :guard, {:halted, :policy}, 12},
        {:end_turn, :limit, {:max_turns_exceeded, 1}, 24},
        {:requires_action, :unresolved, {:unresolved_requires_action, "native-stop"}, 12}
      ] do
    @terminal terminal
    @kind kind
    @error error
    @tokens tokens
    test "boundary stop #{inspect(error)} publishes one completed-boundary result" do
      event = turn(@terminal) |> Map.put("tool", false)

      opts = boundary_options(@kind)

      runner = run_async(FailureProvider, [poll_fun: boundary_poll(@kind, event)] ++ opts)
      expected = @error
      assert_receive {:returned, ^runner, {:error, ^expected}, result, []}, 2_000
      assert result.in_flight == :none
      assert result.usage.input_tokens == @tokens
      assert result.terminal == :terminated
    end
  end

  test "success returns the same single notification and completed boundary" do
    runner = run_async(FailureProvider, poll_fun: fn _, _ -> {:ok, [turn(:end_turn)]} end)
    assert_receive {:returned, ^runner, {:ok, result}, result, []}, 2_000
    assert result.in_flight == :none
    assert result.usage.input_tokens == 12
  end

  test "validation refusals enter no provider and fabricate no result" do
    for {config, reason} <- [
          {%{model: "catalog-model"}, :runtime_model_unsupported},
          {%{api_key: "synthetic"}, :data_plane_unsupported}
        ] do
      runner = run_async(FailureProvider, model_config: config, test_pid: self())
      assert_receive {:returned, ^runner, {:error, ^reason}, :missing, []}, 2_000
      refute_receive {:opened, _}
    end
  end

  test "failed and blocked opens produce no fabricated result" do
    for {open, extra, reason} <- [
          {fn _ -> {:error, :open_failed} end, [], :open_failed},
          {fn _ -> receive do: (:never -> :ok) end, [deadline: now() + 100], :timeout}
        ] do
      runner = run_async(FailureProvider, [open_fun: open, test_pid: self()] ++ extra)
      assert_receive {:opened, _}, 2_000
      assert_receive {:returned, ^runner, {:error, ^reason}, :missing, []}, 2_000
    end
  end

  test "legacy timeout starts after initialization while deadline includes it" do
    test = self()

    open = fn _ ->
      send(test, {:initializing, self()})
      receive do: (:release -> :ok)
    end

    runner =
      run_async(FailureProvider,
        open_fun: open,
        timeout: 20,
        poll_fun: fn _, _ -> {:ok, [turn(:end_turn)]} end
      )

    assert_receive {:initializing, session}, 2_000
    refute_receive {:returned, ^runner, _, _, _}, 40
    send(session, :release)
    assert_receive {:returned, ^runner, {:ok, result}, result, []}, 2_000
  end

  test "streaming failure retains accepted partial events exactly once without counting their usage" do
    test = self()
    partial = %{"id" => "partial", "type" => "text", "text" => "accepted"}

    push = fn subscriber, ref, input ->
      case input do
        :kickoff ->
          send(subscriber, {:managed_agents, ref, {:event, turn(:requires_action)}})

        _ ->
          send(subscriber, {:managed_agents, ref, {:event, partial}})
          send(subscriber, {:managed_agents, ref, {:event, partial}})
          send(subscriber, {:managed_agents, ref, {:error, :stream_lost}})
      end

      send(test, :pushed)
      :ok
    end

    runner = run_async(FailureProvider.Streaming, push_fun: push)
    assert_receive {:returned, ^runner, {:error, :stream_lost}, result, []}, 2_000
    assert %SessionResult{} = result
    assert result.events == [turn(:requires_action), partial]
    assert result.usage.input_tokens == 12
    assert result.turns == 1
    assert result.in_flight == :unknown
  end

  test "deadline during a synchronous tool callback retains the accepted turn" do
    test = self()

    handler = fn _, _, _ ->
      send(test, {:handler, self()})
      receive do: (:release -> {:ok, "late"})
    end

    runner =
      run_async(FailureProvider,
        handler: handler,
        deadline: now() + 300,
        poll_fun: fn _, _ -> {:ok, [turn(:requires_action)]} end
      )

    assert_receive {:handler, worker}, 2_000
    ref = Process.monitor(worker)
    assert_receive {:returned, ^runner, {:error, :timeout}, result, []}, 2_000
    assert %SessionResult{} = result
    assert result.turns == 1
    assert result.usage.input_tokens == 12
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
  end

  test "caller death preserves an accepted result for an independent notification owner" do
    test = self()

    poll = fn
      0, _ ->
        {:ok, [turn(:requires_action)]}

      1, _ ->
        send(test, {:attempt, self()})
        receive do: (:release -> {:error, :late})
    end

    caller = run_async(FailureProvider, poll_fun: poll, notify: test, test_pid: test)
    assert_receive {:opened, session}, 2_000
    assert_receive {:attempt, worker}, 2_000
    refs = for pid <- [session, worker], do: {Process.monitor(pid), pid}
    Process.exit(caller, :kill)
    assert_receive {:managed_agents_session, result}, 2_000
    assert result.terminal == :terminated
    assert result.usage.input_tokens == 12
    assert result.turns == 1
    assert result.in_flight == :unknown
    for {ref, pid} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _})
    refute_receive {:managed_agents_session, _}
  end

  test "a blocked transcript callback cannot lose an already accepted completed turn" do
    test = self()

    transcript = fn _ ->
      send(test, :reading_transcript)
      receive do: (:release -> [])
    end

    runner =
      run_async(FailureProvider,
        transcript_fun: transcript,
        deadline: now() + 300,
        poll_fun: fn _, _ -> {:ok, [turn(:end_turn)]} end
      )

    assert_receive :reading_transcript, 2_000
    assert_receive {:returned, ^runner, {:error, :timeout}, result, []}, 2_000
    assert %SessionResult{} = result
    assert result.turns == 1
    assert result.usage.input_tokens == 12
    assert result.in_flight == :none
  end

  test "an ownership refusal prevents further provider work" do
    test = self()

    poll = fn _, _ ->
      send(test, :polled)
      {:ok, [turn(:end_turn)]}
    end

    positive = run_async(FailureProvider, poll_fun: poll)
    assert_receive {:returned, ^positive, {:ok, _}, _, []}, 2_000
    assert_received :polled

    open = fn opts ->
      :ok = Completion.begin_request(opts[:completion_owner], make_ref(), %SessionResult{})
      :ok
    end

    refused = run_async(FailureProvider, open_fun: open, poll_fun: poll)
    assert_receive {:returned, ^refused, {:error, :normal}, _, []}, 2_000
    refute_receive :polled
  end

  test "consumer death preserves completed usage during the next streaming attempt" do
    test = self()

    consumer = fn _, _ ->
      spawn_link(fn ->
        send(test, {:consumer, self()})
        receive do: (:drop -> exit(:stream_boom))
      end)
    end

    push = fn subscriber, ref, input ->
      if input == :kickoff,
        do: send(subscriber, {:managed_agents, ref, {:event, turn(:requires_action)}}),
        else: send(test, :next_attempt)

      :ok
    end

    runner = run_async(FailureProvider.Streaming, push_fun: push, consumer_fun: consumer)
    assert_receive {:consumer, worker}, 2_000
    assert_receive :next_attempt, 2_000
    send(worker, :drop)
    assert_receive {:returned, ^runner, {:error, :stream_boom}, result, []}, 2_000
    assert %SessionResult{} = result
    assert result.usage.input_tokens == 12
    assert result.turns == 1
    assert result.in_flight == :unknown
  end

  defmodule BlockingEventHandler do
    def handle_tool(_, _, _), do: {:ok, "done"}

    def handle_event(%{"type" => "text"}, test, _) do
      send(test, {:event_blocked, self()})
      receive do: (:release -> :ok)
    end

    def handle_event(_, _, _), do: :ok
  end

  test "a blocked streaming event callback cannot lose the accepted partial event" do
    partial = %{"id" => "partial", "type" => "text", "text" => "accepted"}

    push = fn subscriber, ref, input ->
      event = if input == :kickoff, do: turn(:requires_action), else: partial
      send(subscriber, {:managed_agents, ref, {:event, event}})
      :ok
    end

    runner =
      run_async(FailureProvider.Streaming,
        push_fun: push,
        handler: BlockingEventHandler,
        context: self(),
        deadline: now() + 300
      )

    assert_receive {:event_blocked, _}, 2_000
    assert_receive {:returned, ^runner, {:error, :timeout}, result, []}, 2_000
    assert %SessionResult{} = result
    assert result.events == [turn(:requires_action), partial]
    assert result.usage.input_tokens == 12
    assert result.turns == 1
  end

  test "live messages reset usage and idle shutdown does not send another result" do
    {:ok, session} =
      Session.start_link(FailureProvider,
        handler: fn _, _, _ -> {:ok, "done"} end,
        notify: self(),
        poll_fun: fn _, _ -> {:ok, [turn(:end_turn)]} end
      )

    assert_receive {:managed_agents_session, first}, 2_000
    assert first.in_flight == :none
    Session.message(session, "next")
    assert_receive {:managed_agents_session, second}, 2_000
    assert second.turns == 1
    assert second.usage.input_tokens == 12
    assert second.in_flight == :none
    GenServer.stop(session)
    refute_receive {:managed_agents_session, _}
  end

  test "live messages arriving during a request queue in order with separate usage" do
    test = self()

    poll = fn index, input ->
      if index == 0 do
        send(test, {:first_attempt, self()})
        receive do: (:release -> :ok)
      end

      tokens =
        case input do
          :kickoff -> 12
          {:user, "next"} -> 24
          {:user, "last"} -> 36
        end

      event = turn(:end_turn) |> put_in(["usage", :input_tokens], tokens)
      {:ok, [event]}
    end

    {:ok, session} =
      Session.start_link(FailureProvider,
        handler: fn _, _, _ -> {:ok, "done"} end,
        notify: self(),
        poll_fun: poll
      )

    assert_receive {:first_attempt, worker}, 2_000
    Session.message(session, "next")
    Session.message(session, "last")
    send(worker, :release)

    for tokens <- [12, 24, 36] do
      assert_receive {:managed_agents_session, result}, 2_000
      assert result.terminal == :end_turn
      assert result.turns == 1
      assert result.usage.input_tokens == tokens
    end

    GenServer.stop(session)
    refute_receive {:managed_agents_session, _}
  end

  test "retired stream frames cannot execute tools or complete another request" do
    test = self()

    push = fn subscriber, ref, input ->
      send(test, {:stream, subscriber, ref})
      id = if input == :kickoff, do: "first", else: "next"
      event = Map.put(turn(:end_turn), "id", id)
      send(subscriber, {:managed_agents, ref, {:event, event}})
      :ok
    end

    handler = fn _, _, _ ->
      send(test, :unexpected_tool)
      {:ok, "done"}
    end

    {:ok, session} =
      Session.start_link(FailureProvider.Streaming,
        handler: handler,
        notify: self(),
        push_fun: push
      )

    assert_receive {:stream, ^session, ref}, 2_000
    assert_receive {:managed_agents_session, first}, 2_000
    assert first.usage.input_tokens == 12
    retired = Map.put(turn(:requires_action), "id", "retired")
    send(session, {:managed_agents, ref, {:event, retired}})
    refute_receive :unexpected_tool
    refute_receive {:managed_agents_session, _}
    Session.message(session, "next")
    assert_receive {:managed_agents_session, second}, 2_000
    assert second.usage.input_tokens == 12
    assert second.turns == 1
    GenServer.stop(session)
  end

  test "a recovered terminal releases the queued live message with fresh usage" do
    session = recovering_session([turn(:end_turn)])
    Session.message(session, "queued")
    send(session, :reconnect)
    assert_receive {:managed_agents_session, first}, 2_000
    assert first.turns == 1
    assert first.usage.input_tokens == 12
    assert_receive {:managed_agents_session, second}, 2_000
    assert second.turns == 1
    assert second.usage.input_tokens == 24
    assert second.session_id == first.session_id
    GenServer.stop(session)
    refute_receive {:managed_agents_session, _}
  end

  defmodule RecoveryEventHandler do
    def handle_tool(_, _, test_pid) do
      send(test_pid, :unexpected_recovery_tool)
      {:ok, "done"}
    end

    def handle_event(event, test_pid, _), do: send(test_pid, {:recovery_observation, event})
  end

  for queued? <- [false, true] do
    @queued queued?
    test "history after recovered completion stays observational (queued: #{@queued})" do
      tail = %{"id" => "unowned-tail", "type" => "text", "text" => "observed"}
      session = recovering_session([turn(:end_turn), tail])
      if @queued, do: Session.message(session, "next")
      send(session, :reconnect)
      assert_receive {:managed_agents_session, first}, 2_000
      assert first.turns == 1
      assert first.usage.input_tokens == 12
      assert_receive {:recovery_observation, ^tail}, 2_000
      unless @queued, do: Session.message(session, "next")
      assert_receive {:managed_agents_session, second}, 2_000
      assert second.turns == 1
      assert second.usage.input_tokens == 24
      refute_receive :unexpected_recovery_tool
      GenServer.stop(session)
      refute_receive {:managed_agents_session, _}
    end
  end

  defp recovering_session(recovered) do
    test_pid = self()
    next = put_in(turn(:end_turn), ["usage", :input_tokens], 24) |> Map.put("id", "next")

    push = fn subscriber, ref, input ->
      case input do
        :kickoff -> send(test_pid, :recovering_started)
        {:user, _} -> send(subscriber, {:managed_agents, ref, {:event, next}})
      end

      :ok
    end

    reconnect = fn conn, _subscriber, seen ->
      seen = Enum.reduce(recovered, seen, &MapSet.put(&2, &1["id"]))
      {:ok, conn, [], seen, recovered}
    end

    {:ok, session} =
      Session.start_link(FailureProvider.Streaming,
        handler: RecoveryEventHandler,
        context: test_pid,
        notify: test_pid,
        push_fun: push,
        reconnect_fun: reconnect
      )

    Process.unlink(session)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
    assert_receive :recovering_started
    session
  end

  defp run_async(provider, opts) do
    test = self()

    spawn(fn ->
      result =
        Session.run(
          provider,
          Keyword.merge([handler: fn _, _, _ -> {:ok, "done"} end, notify: self()], opts)
        )

      snapshot =
        receive do: ({:managed_agents_session, snapshot} -> snapshot), after: (0 -> :missing)

      residue = drain([])
      send(test, {:returned, self(), result, snapshot, residue})
    end)
  end

  defp drain(acc) do
    receive do
      {:managed_agents_session, result} -> drain([result | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp turn(terminal) do
    %{
      "id" => "completed",
      "type" => "turn",
      "terminal" => terminal,
      "stop_reason" => "native-stop",
      "tool" => terminal == :requires_action,
      "usage" => %{
        input_tokens: 12,
        output_tokens: 4,
        cache_read_input_tokens: 3,
        cache_creation_input_tokens: 2,
        input_token_basis: :uncached
      }
    }
  end

  defp release_failure(failure, worker, _session) when failure in [:transport, :crash],
    do: send(worker, :release)

  defp release_failure(:session_death, _worker, session), do: Process.exit(session, :kill)
  defp release_failure(_, _, _), do: :ok

  defp expected_failure(:transport), do: :transport_down
  defp expected_failure(:crash), do: :poll_boom
  defp expected_failure(:session_death), do: :killed
  defp expected_failure(_), do: :timeout

  defp failure_options(:timeout, opts), do: opts ++ [timeout: 300]
  defp failure_options(:deadline, opts), do: opts ++ [deadline: now() + 300]
  defp failure_options(_, opts), do: opts
  defp failure_response(:transport), do: {:error, :transport_down}
  defp failure_response(:crash), do: exit(:poll_boom)
  defp failure_response(_), do: {:ok, [turn(:end_turn)]}
  defp boundary_options(:guard), do: [turn_guard: fn _ -> {:halt, :policy} end]
  defp boundary_options(:limit), do: [max_turns: 1]
  defp boundary_options(:unresolved), do: []

  defp boundary_poll(:limit, event) do
    fn
      0, _ -> {:ok, [turn(:requires_action)]}
      1, _ -> {:ok, [event]}
    end
  end

  defp boundary_poll(_, event), do: fn _, _ -> {:ok, [event]} end

  defp now, do: System.monotonic_time(:millisecond)
end
