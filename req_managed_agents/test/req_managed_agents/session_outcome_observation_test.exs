defmodule ReqManagedAgents.SessionOutcomeObservationTest do
  @moduledoc """
  Typed outcomes on published Session results, driven through documented-shape
  synthetic events. Claude cases run over Bypass; failure, reset and recovery cases
  use a streaming fake whose only addition is the optional `outcome_results/1`
  callback, delegating to the Claude projection.
  """
  use ExUnit.Case

  import ExUnit.CaptureLog
  import ReqManagedAgents.SSEFixtures

  alias ReqManagedAgents.{Client, Provider, Session, SessionResult, Usage}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.{Event, Grading}
  alias ReqManagedAgents.Test.FailureProvider
  alias ReqManagedAgents.Test.NativeOutcomeFixtures, as: Fixtures

  defmodule Graded do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    alias ReqManagedAgents.Providers.ClaudeManagedAgents.Grading
    alias ReqManagedAgents.Test.FailureProvider.Streaming

    @impl true
    def mode, do: :streaming
    @impl true
    defdelegate provision(spec, opts), to: Streaming
    @impl true
    defdelegate open(opts, subscriber), to: Streaming
    @impl true
    defdelegate reconnect_with_events(conn, subscriber, seen), to: Streaming
    @impl true
    defdelegate kickoff_input(opts), to: Streaming
    @impl true
    defdelegate user_input(text), to: Streaming
    @impl true
    defdelegate resume_input(uses, results), to: Streaming
    @impl true
    defdelegate push_input(conn, input), to: Streaming
    @impl true
    defdelegate turn_boundary?(event), to: Streaming
    @impl true
    defdelegate normalize(events), to: Streaming
    @impl true
    defdelegate session_id(conn), to: Streaming
    @impl true
    defdelegate ref(conn), to: Streaming
    @impl true
    defdelegate consumer(conn), to: Streaming
    @impl true
    defdelegate resumed?(conn), to: Streaming

    @impl true
    def outcome_results(events), do: Grading.outcome_results(events)
  end

  defmodule GradedRequestResponse do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    alias ReqManagedAgents.Providers.ClaudeManagedAgents.Grading
    alias ReqManagedAgents.Test.FailureProvider

    @impl true
    def mode, do: :request_response
    @impl true
    defdelegate provision(spec, opts), to: FailureProvider
    @impl true
    defdelegate open(opts, subscriber), to: FailureProvider
    @impl true
    defdelegate kickoff_input(opts), to: FailureProvider
    @impl true
    defdelegate user_input(text), to: FailureProvider
    @impl true
    defdelegate resume_input(uses, results), to: FailureProvider
    @impl true
    defdelegate poll_turn(conn, input), to: FailureProvider
    @impl true
    defdelegate turn_boundary?(event), to: FailureProvider
    @impl true
    defdelegate normalize(events), to: FailureProvider
    @impl true
    defdelegate session_id(conn), to: FailureProvider
    @impl true
    defdelegate ref(conn), to: FailureProvider
    @impl true
    defdelegate consumer(conn), to: FailureProvider
    @impl true
    defdelegate resumed?(conn), to: FailureProvider

    @impl true
    def outcome_results(events), do: Grading.outcome_results(events)
  end

  defmodule Observer do
    @moduledoc false
    def handle_tool_call(_name, _input, _ctx), do: {:ok, "done"}

    def handle_event(%{"id" => id} = event, test_pid, _info) do
      send(test_pid, {:observed, id, event})
      :ok
    end

    def handle_event(_event, _test_pid, _info), do: :ok
  end

  defmodule Telemetry do
    @moduledoc false
    def forward(_event, measurements, metadata, test_pid),
      do: send(test_pid, {:unknown_outcome_result, measurements, metadata})
  end

  setup do
    bypass = Bypass.open()
    client = Client.new(api_key: "sk", base_url: "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass, client: client}
  end

  # ── Claude over Bypass ───────────────────────────────────────────────────────

  describe "a successful Claude session" do
    for final <- [:satisfied, :max_iterations_reached] do
      @final final
      test "carries the typed outcome and holds the idle boundary after a #{final} grade", %{
        bypass: bypass,
        client: client
      } do
        hold_idle_after(@final, bypass, client)
      end
    end

    defp hold_idle_after(final, bypass, client) do
      test = self()

      events = [
        Fixtures.definition("outc-1"),
        Fixtures.evaluation("outc-1", 0, :needs_revision, explanation: "Missing total"),
        agent_text("m1", "draft"),
        Fixtures.evaluation("outc-1", 1, final, explanation: "Final grade")
      ]

      mock_session(bypass, fn conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, wire(events))
        send(test, {:stream, self()})
        receive do: (:release -> :ok)
        {:ok, conn} = Plug.Conn.chunk(conn, wire([agent_text("ack", "ack"), end_turn()]))
        conn
      end)

      runner = run_async(client, handler: Observer, context: test)
      assert_receive {:stream, stream}, 2_000
      satisfied_id = "end-outc-1-1"
      assert_receive {:observed, ^satisfied_id, _}, 2_000
      refute_receive {:returned, ^runner, _, _}, 100

      send(stream, :release)
      assert_receive {:returned, ^runner, {:ok, result}, []}, 2_000

      assert result.terminal == :end_turn
      assert result.stop_reason == %{"type" => "end_turn"}
      assert result.text == "draft\nack"
      assert %Usage{input_tokens: 0, output_tokens: 0, raw: []} = result.usage
      assert result.turns == 1
      assert result.events == events ++ [agent_text("ack", "ack"), end_turn()]
      assert [%{outcome_id: "outc-1", status: ^final}] = result.outcomes

      assert Enum.map(hd(result.outcomes).evaluations, & &1.result) == [
               :needs_revision,
               final
             ]

      assert result.outcomes == Provider.outcome_results(ClaudeManagedAgents, result.events)
    end

    test "wire garbage inside outcome events cannot crash the Session", %{
      bypass: bypass,
      client: client
    } do
      garbage_end =
        Fixtures.evaluation("outc-g", 0, :satisfied, id: "end-garbage")
        |> Map.merge(%{
          "iteration" => "zero",
          "result" => 3,
          "explanation" => ["not text"],
          "outcome_evaluation_start_id" => 7,
          "processed_at" => %{"at" => "now"}
        })

      events = [
        agent_text("m1", "ok"),
        Fixtures.definition("outc-g", description: 5),
        garbage_end,
        Map.put(Fixtures.start("outc-x", 0), "outcome_id", 12),
        %{"type" => "span.outcome_evaluation_end", "id" => "bare"}
      ]

      mock_session(bypass, fn conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, wire(events ++ [end_turn()]))
        conn
      end)

      assert {:ok, result} = Session.run(ClaudeManagedAgents, run_opts(client))
      assert result.terminal == :end_turn
      assert result.text == "ok"
      assert [outcome] = result.outcomes
      assert outcome.outcome_id == "outc-g"
      assert outcome.status == :unknown

      assert Enum.sort(outcome.issues) ==
               Enum.sort([
                 :invalid_description,
                 :invalid_start_event_id,
                 :invalid_iteration,
                 :unknown_result,
                 :invalid_explanation,
                 :invalid_processed_at
               ])

      assert [%{result: :unknown, iteration: nil, raw: ^garbage_end}] = outcome.evaluations
    end
  end

  describe "unknown-verdict telemetry" do
    setup do
      id = "unknown-outcome-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:req_managed_agents, :session, :unknown_outcome_result],
        &Telemetry.forward/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "an unknown verdict re-projected by later events is counted once", %{
      bypass: bypass,
      client: client
    } do
      events = [
        Fixtures.definition("outc-1"),
        Fixtures.evaluation("outc-1", 0, "brand_new_verdict"),
        agent_text("m1", "after"),
        Fixtures.ongoing("outc-1", 1),
        end_turn()
      ]

      mock_session(bypass, fn conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, wire(events))
        conn
      end)

      log =
        capture_log([level: :debug], fn ->
          opts = run_opts(client) ++ [telemetry_metadata: %{tenant: "t-1", outcome_ids: :caller}]
          assert {:ok, result} = Session.run(ClaudeManagedAgents, opts)
          assert [%{status: :unknown, evaluations: [%{result: :unknown}]}] = result.outcomes
        end)

      assert_received {:unknown_outcome_result, %{unknown_count: 1},
                       %{outcome_ids: ["outc-1"], tenant: "t-1"}}

      refute_received {:unknown_outcome_result, _, _}
      assert log =~ "unknown_outcome_result"
      assert log =~ "outc-1"
    end

    test "a repeated identical unknown verdict is counted again", %{
      bypass: bypass,
      client: client
    } do
      unknown = Fixtures.evaluation("outc-1", 0, "brand_new_verdict") |> Map.delete("id")

      mock_session(bypass, fn conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, wire([Fixtures.definition("outc-1"), unknown]))
        {:ok, conn} = Plug.Conn.chunk(conn, wire([unknown]))
        {:ok, conn} = Plug.Conn.chunk(conn, wire([end_turn()]))
        conn
      end)

      assert {:ok, result} = Session.run(ClaudeManagedAgents, run_opts(client))
      assert [%{evaluations: [_, _]}] = result.outcomes

      assert_received {:unknown_outcome_result, %{unknown_count: 1}, %{outcome_ids: ["outc-1"]}}
      assert_received {:unknown_outcome_result, %{unknown_count: 1}, %{outcome_ids: ["outc-1"]}}
      refute_received {:unknown_outcome_result, _, _}
    end

    test "known verdicts emit nothing", %{bypass: bypass, client: client} do
      mock_session(bypass, fn conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, wire(Fixtures.happy() |> List.delete_at(-1)))
        {:ok, conn} = Plug.Conn.chunk(conn, wire([end_turn()]))
        conn
      end)

      assert {:ok, %{outcomes: [%{status: :satisfied}]}} =
               Session.run(ClaudeManagedAgents, run_opts(client))

      refute_received {:unknown_outcome_result, _, _}
    end

    test "chained outcomes each count their own unknown verdict once", %{
      bypass: bypass,
      client: client
    } do
      session = start_chain(bypass, client, unknown?: true)

      assert_receive {:managed_agents_session, first}, 2_000
      assert [%{outcome_id: "outc-A", status: :unknown}] = first.outcomes
      assert_received {:unknown_outcome_result, %{unknown_count: 1}, %{outcome_ids: ["outc-A"]}}

      release_second(session)
      assert_receive {:managed_agents_session, second}, 2_000
      assert Enum.map(second.outcomes, & &1.outcome_id) == ["outc-A", "outc-B"]
      assert_received {:unknown_outcome_result, %{unknown_count: 1}, %{outcome_ids: ["outc-B"]}}
      refute_received {:unknown_outcome_result, _, _}

      Session.message(session.pid, "plain")
      send(session.stream, :release_third)
      assert_receive {:managed_agents_session, %SessionResult{outcomes: []}}, 2_000
    end
  end

  describe "send_event/2 chaining and message/2 reset" do
    test "outcomes accumulate across chained definitions and reset with a message", %{
      bypass: bypass,
      client: client
    } do
      session = start_chain(bypass, client, unknown?: false)

      assert_receive {:managed_agents_session, first}, 2_000
      assert [%{outcome_id: "outc-A", status: :satisfied}] = first.outcomes

      release_second(session)
      assert_receive {:managed_agents_session, second}, 2_000
      assert Enum.map(second.outcomes, & &1.outcome_id) == ["outc-A", "outc-B"]
      assert hd(second.outcomes).outcome_id == "outc-A"
      assert [_, %{status: :needs_revision, evaluations: [_]}] = second.outcomes
      assert second.outcomes == Provider.outcome_results(ClaudeManagedAgents, second.events)

      Session.message(session.pid, "plain")
      send(session.stream, :release_third)
      assert_receive {:managed_agents_session, third}, 2_000
      assert third.outcomes == []
      assert third.text == "plain reply"
    end
  end

  # ── partial and failure snapshots (streaming fake) ───────────────────────────

  describe "failure snapshots carry the checkpointed outcomes" do
    for {failure, expected} <- [
          {:timeout, :timeout},
          {:transport, :stream_lost},
          {:session_death, :killed}
        ],
        {grade, status, iteration} <- [
          {:needs_revision, :needs_revision, 0},
          {:satisfied, :satisfied, 1}
        ] do
      @failure failure
      @expected expected
      @grade grade
      @status status
      @iteration iteration
      test "#{failure} after a #{grade} grade keeps one typed notification" do
        grade = @grade
        end_event = Fixtures.evaluation("outc-1", @iteration, grade)
        events = [Fixtures.definition("outc-1"), end_event]
        end_id = end_event["id"]

        push = fn subscriber, ref, :kickoff ->
          for event <- events, do: send(subscriber, {:managed_agents, ref, {:event, event}})

          if @failure == :transport,
            do: send(subscriber, {:managed_agents, ref, {:error, :stream_lost}})

          :ok
        end

        opts = [push_fun: push, handler: Observer, context: self(), test_pid: self()]
        opts = if @failure == :timeout, do: opts ++ [timeout: 800], else: opts
        runner = run_graded(Graded, opts)

        assert_receive {:opened, session}, 2_000
        assert_receive {:observed, ^end_id, _}, 2_000
        if @failure == :session_death, do: Process.exit(session, :kill)

        expected = @expected
        assert_receive {:returned, ^runner, {:error, ^expected}, notification, []}, 2_000
        assert %SessionResult{in_flight: :unknown} = notification

        assert [%{outcome_id: "outc-1", status: @status, evaluations: [%{iteration: @iteration}]}] =
                 notification.outcomes

        assert notification.outcomes == Provider.outcome_results(Graded, notification.events)
        assert notification.events == events
      end
    end
  end

  # ── resets, recovery and dispatch (streaming fake) ───────────────────────────

  describe "live messages and recovery" do
    test "a message resets outcomes and a new id never inherits earlier evaluations" do
      push = fn subscriber, ref, input ->
        events =
          case input do
            :kickoff -> graded_turn("a", :satisfied)
            {:user, "b"} -> graded_turn("b", :needs_revision)
            {:user, "none"} -> [turn("t-none")]
          end

        for event <- events, do: send(subscriber, {:managed_agents, ref, {:event, event}})
        :ok
      end

      {:ok, session} =
        Session.start_link(Graded,
          handler: fn _, _, _ -> {:ok, "done"} end,
          notify: self(),
          push_fun: push
        )

      assert_receive {:managed_agents_session, first}, 2_000
      assert [%{outcome_id: "o-a", status: :satisfied}] = first.outcomes

      Session.message(session, "b")
      assert_receive {:managed_agents_session, second}, 2_000
      assert [%{outcome_id: "o-b", status: :needs_revision, evaluations: [_]}] = second.outcomes

      Session.message(session, "none")
      assert_receive {:managed_agents_session, third}, 2_000
      assert third.outcomes == []
      stop(session)
    end

    # The first event of a message replaces the snapshot's events, so only a message that
    # fails before any event shows whether it started from a fresh snapshot.
    test "a message that fails before any event publishes no earlier outcomes" do
      push = fn subscriber, ref, input ->
        case input do
          :kickoff ->
            for event <- graded_turn("a", :satisfied),
                do: send(subscriber, {:managed_agents, ref, {:event, event}})

            :ok

          {:user, "b"} ->
            {:error, :push_refused}
        end
      end

      {:ok, session} =
        Session.start_link(Graded,
          handler: fn _, _, _ -> {:ok, "done"} end,
          notify: self(),
          push_fun: push
        )

      assert_receive {:managed_agents_session, first}, 2_000
      assert [%{outcome_id: "o-a", status: :satisfied}] = first.outcomes

      Session.message(session, "b")
      assert_receive {:managed_agents_session, failed}, 2_000
      assert failed.events == []
      assert failed.outcomes == []
      stop(session)
    end

    test "events accepted through a reconnect project with their raw scope, once" do
      graded = Fixtures.evaluation("outc-1", 0, :satisfied, id: "recovered-end")
      closing = turn("closing")
      recovered = [graded, closing]

      push = fn subscriber, ref, input ->
        case input do
          :kickoff ->
            send(
              subscriber,
              {:managed_agents, ref, {:event, requires_action_turn("first")}}
            )

          {:resume, _} ->
            send(subscriber, :reconnect)
            for event <- recovered, do: send(subscriber, {:managed_agents, ref, {:event, event}})
        end

        :ok
      end

      reconnect = fn conn, _subscriber, seen ->
        {:ok, conn, [], MapSet.union(seen, MapSet.new(["recovered-end", "closing"])), recovered}
      end

      runner = run_graded(Graded, push_fun: push, reconnect_fun: reconnect)
      assert_receive {:returned, ^runner, {:ok, result}, notification, []}, 2_000
      assert notification == result
      assert Enum.count(result.events, &(&1["id"] == "recovered-end")) == 1
      assert [%{outcome_id: "outc-1", status: :satisfied, evaluations: [_]}] = result.outcomes
      assert result.outcomes == Provider.outcome_results(Graded, result.events)
    end

    test "history observed after a recovered completion creates no typed grade" do
      test = self()
      tail = Fixtures.evaluation("outc-late", 0, :failed, id: "unowned-tail")
      head = Fixtures.evaluation("outc-1", 0, :satisfied, id: "head-end")

      push = fn subscriber, ref, input ->
        case input do
          :kickoff ->
            send(test, :started)

          {:user, _} ->
            for e <- turn_with_id("next"),
                do: send(subscriber, {:managed_agents, ref, {:event, e}})
        end

        :ok
      end

      reconnect = fn conn, _subscriber, seen ->
        {:ok, conn, [], seen, [head, turn("closing"), tail]}
      end

      {:ok, session} =
        Session.start_link(Graded,
          handler: Observer,
          context: test,
          notify: test,
          push_fun: push,
          reconnect_fun: reconnect
        )

      Process.unlink(session)
      on_exit(fn -> stop(session) end)
      assert_receive :started, 2_000
      send(session, :reconnect)

      assert_receive {:managed_agents_session, first}, 2_000
      assert [%{outcome_id: "outc-1"}] = first.outcomes
      assert_receive {:observed, "unowned-tail", ^tail}, 2_000
      refute Enum.any?(first.outcomes, &(&1.outcome_id == "outc-late"))
      refute tail in first.events
      assert first.outcomes == Provider.outcome_results(Graded, first.events)
    end

    test "a live event from a failed request-response attempt creates no typed grade" do
      test = self()
      live = Fixtures.evaluation("outc-live", 0, :satisfied, id: "live-end")

      poll = fn _index, _input ->
        send(test, {:attempt, self()})
        receive do: ({:session, session} -> send(session, {:provider_event, live}))
        {:error, :attempt_failed}
      end

      runner =
        run_graded(GradedRequestResponse,
          poll_fun: poll,
          handler: Observer,
          context: test
        )

      assert_receive {:opened, session}, 2_000
      assert_receive {:attempt, worker}, 2_000
      send(worker, {:session, session})

      assert_receive {:observed, "live-end", ^live}, 2_000
      assert_receive {:returned, ^runner, {:error, :attempt_failed}, notification, []}, 2_000
      assert notification.outcomes == []
      assert notification.events == []

      assert notification.outcomes ==
               Provider.outcome_results(GradedRequestResponse, notification.events)
    end

    test "a provider without the callback reports [] for Claude-shaped events" do
      events = [Fixtures.definition("outc-1"), Fixtures.evaluation("outc-1", 0, :satisfied)]

      push = fn subscriber, ref, :kickoff ->
        for event <- events ++ [turn("done")],
            do: send(subscriber, {:managed_agents, ref, {:event, event}})

        :ok
      end

      refute function_exported?(FailureProvider.Streaming, :outcome_results, 1)
      runner = run_graded(FailureProvider.Streaming, push_fun: push)
      assert_receive {:returned, ^runner, {:ok, result}, _notification, []}, 2_000
      assert Enum.take(result.events, 2) == events
      assert result.outcomes == []
      assert Grading.outcome_results(result.events) != []
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp agent_text(id, text),
    do: %{
      "type" => "agent.message",
      "id" => id,
      "content" => [%{"type" => "text", "text" => text}]
    }

  defp mock_session(bypass, stream_fun) do
    test = self()

    Bypass.expect_once(bypass, "POST", "/v1/sessions", fn conn ->
      Req.Test.json(conn, %{"id" => "s1"})
    end)

    Bypass.expect_once(bypass, "GET", "/v1/sessions/s1/events/stream", fn conn ->
      stream_fun.(Plug.Conn.send_chunked(conn, 200))
    end)

    Bypass.expect(bypass, "POST", "/v1/sessions/s1/events", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posted, Jason.decode!(body)})
      Req.Test.json(conn, %{"ok" => true})
    end)
  end

  defp run_opts(client),
    do: [
      client: client,
      handler: fn _name, _input, _ctx -> {:ok, ""} end,
      agent_id: "ag",
      environment_id: "env",
      timeout: 5_000
    ]

  defp run_async(client, extra) do
    test = self()

    spawn(fn ->
      result = Session.run(ClaudeManagedAgents, Keyword.merge(run_opts(client), extra))
      send(test, {:returned, self(), result, drain([])})
    end)
  end

  defp run_graded(provider, opts) do
    test = self()

    spawn(fn ->
      base = [handler: fn _, _, _ -> {:ok, "done"} end, notify: self(), test_pid: test]
      result = Session.run(provider, Keyword.merge(base, opts))

      snapshot =
        receive do: ({:managed_agents_session, snapshot} -> snapshot), after: (0 -> :missing)

      send(test, {:returned, self(), result, snapshot, drain([])})
    end)
  end

  defp drain(acc) do
    receive do
      {:managed_agents_session, result} -> drain([result | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A live session over Bypass: outcome A completes, the stream then blocks until the
  # test releases it for outcome B, then once more for a plain turn.
  defp start_chain(bypass, client, unknown?: unknown?) do
    test = self()
    verdict_a = if unknown?, do: "brand_new_verdict", else: "satisfied"
    verdict_b = if unknown?, do: "other_new_verdict", else: "needs_revision"

    mock_session(bypass, fn conn ->
      first = [
        Fixtures.definition("outc-A"),
        Fixtures.evaluation("outc-A", 0, verdict_a),
        end_turn()
      ]

      {:ok, conn} = Plug.Conn.chunk(conn, wire(first))
      send(test, {:stream, self()})
      receive do: (:release_second -> :ok)

      second = [
        Fixtures.definition("outc-B"),
        Fixtures.evaluation("outc-B", 0, verdict_b),
        end_turn()
      ]

      {:ok, conn} = Plug.Conn.chunk(conn, wire(second))
      receive do: (:release_third -> :ok)

      {:ok, conn} =
        Plug.Conn.chunk(conn, wire([agent_text("plain-1", "plain reply"), end_turn()]))

      conn
    end)

    {:ok, pid} =
      Session.start_link(ClaudeManagedAgents,
        client: client,
        agent_id: "ag",
        environment_id: "env",
        prompt: "go",
        handler: fn _, _, _ -> {:ok, ""} end,
        notify: test
      )

    Process.unlink(pid)
    on_exit(fn -> stop(pid) end)
    assert_receive {:stream, stream}, 2_000
    %{pid: pid, stream: stream}
  end

  defp release_second(%{pid: pid, stream: stream}) do
    assert :ok = Session.send_event(pid, Event.define_outcome("goal B", "- b"))
    send(stream, :release_second)
  end

  # The stream handler may already be gone, which ends the Session with :shutdown.
  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp turn(id),
    do: %{
      "id" => id,
      "type" => "turn",
      "terminal" => :end_turn,
      "stop_reason" => "native-stop",
      "usage" => %{input_tokens: 1, output_tokens: 1}
    }

  defp requires_action_turn(id),
    do: Map.merge(turn(id), %{"terminal" => :requires_action, "tool" => true})

  defp turn_with_id(id), do: [turn(id)]

  defp graded_turn(suffix, verdict) do
    outcome = "o-#{suffix}"

    [
      Fixtures.evaluation(outcome, 0, verdict, id: "end-#{suffix}"),
      turn("turn-#{suffix}")
    ]
  end
end
