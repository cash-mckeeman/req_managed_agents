defmodule ReqManagedAgents.SessionSendEventTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.{Event, Session, SessionResult}

  # Streaming fake: scripted turns served on push_input, exactly like FakeProviders.Streaming
  # but defined locally for clarity in the regression test.
  defmodule TwoTurnStreaming do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    alias ReqManagedAgents.{ToolUse, TurnResult, Usage}
    @impl true
    def mode, do: :streaming
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, subscriber) do
      {:ok, agent} = Agent.start_link(fn -> opts[:turns] || [] end)
      ref = make_ref()
      send(subscriber, {:managed_agents, ref, :connected})
      {:ok, %{agent: agent, subscriber: subscriber, ref: ref}}
    end

    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}
    @impl true
    def push_input(conn, _input) do
      turn =
        Agent.get_and_update(conn.agent, fn
          [t | rest] -> {t, rest}
          [] -> {[%{"type" => "stop", "terminal" => :end_turn}], []}
        end)

      Enum.each(turn, fn ev ->
        send(conn.subscriber, {:managed_agents, conn.ref, {:event, ev}})
      end)

      :ok
    end

    @impl true
    def turn_boundary?(%{"type" => "stop"}), do: true
    def turn_boundary?(_), do: false

    @impl true
    def normalize(events) do
      customs =
        for %{"type" => "tool"} = e <- events,
            do: %ToolUse{id: e["id"], name: e["name"], input: e["input"]}

      terminal =
        Enum.find_value(events, :terminated, fn
          %{"type" => "stop", "terminal" => t} -> t
          _ -> nil
        end)

      %TurnResult{
        terminal: terminal,
        stop_reason: to_string(terminal),
        custom_tool_uses: customs,
        server_tool_uses: [],
        text: "",
        usage: %Usage{input_tokens: 1, output_tokens: 1, raw: [%{}]},
        events: events
      }
    end

    @impl true
    def session_id(_conn), do: nil
    @impl true
    def ref(conn), do: conn.ref
    @impl true
    def consumer(_conn), do: nil
    @impl true
    def resumed?(_conn), do: false
  end

  # Streaming fake that records pushed inputs instead of scripting turns.
  defmodule PushRecorder do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :streaming
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, subscriber) do
      ref = make_ref()
      send(subscriber, {:managed_agents, ref, :connected})
      {:ok, %{test_pid: opts[:test_pid], ref: ref}}
    end

    @impl true
    def kickoff_input(_opts), do: [:kickoff]
    @impl true
    def user_input(text), do: [{:user, text}]
    @impl true
    def resume_input(_uses, results), do: [{:resume, results}]
    @impl true
    def push_input(conn, events) do
      send(conn.test_pid, {:pushed, events})
      :ok
    end

    @impl true
    def turn_boundary?(_), do: false
    @impl true
    def normalize(events), do: %ReqManagedAgents.TurnResult{terminal: :terminated, events: events}

    @impl true
    def session_id(_conn), do: nil
    @impl true
    def ref(conn), do: conn.ref
    @impl true
    def consumer(_conn), do: nil
    @impl true
    def resumed?(_conn), do: false
  end

  test "send_event/2 pushes the raw event on a streaming session" do
    {:ok, pid} =
      Session.start_link(PushRecorder, handler: fn _, _, _ -> {:ok, ""} end, test_pid: self())

    assert_receive {:pushed, [:kickoff]}

    event = Event.tool_confirmation("tu_1", :allow)
    assert :ok = Session.send_event(pid, event)
    assert_receive {:pushed, [^event]}
  end

  test "send_event/2 regression: second turn's events do not contain first turn's events" do
    # Turn 1: a first scripted end_turn (so the session stays alive for a follow-up).
    turn1 = [%{"type" => "ev1", "id" => "e1"}, %{"type" => "stop", "terminal" => :end_turn}]
    # Turn 2: distinct events emitted after send_event provokes a new push.
    turn2 = [%{"type" => "ev2", "id" => "e2"}, %{"type" => "stop", "terminal" => :end_turn}]

    {:ok, pid} =
      Session.start_link(TwoTurnStreaming,
        handler: fn _, _, _ -> {:ok, ""} end,
        notify: self(),
        turns: [turn1, turn2]
      )

    # Wait for the first turn result.
    assert_receive {:managed_agents_session, %SessionResult{turns: 1, events: events1}}, 2_000
    assert length(events1) == 2

    # Trigger a second turn via send_event.
    :ok = Session.send_event(pid, %{"type" => "user.tool_confirmation"})

    # Wait for the second turn result.
    assert_receive {:managed_agents_session, %SessionResult{turns: 2, events: events2}}, 2_000

    # Fix 1: SessionResult.events is cumulative (turn1 + turn2), but turn1 events must appear
    # exactly once — the turn_events buffer must be cleared on each handle_turn so they are
    # not re-appended into the accumulator on the next turn.
    e1_count = Enum.count(events2, fn e -> e["id"] == "e1" end)

    assert e1_count == 1,
           "turn_events was not cleared: first turn's events duplicated (count=#{e1_count})"

    assert Enum.any?(events2, fn e -> e["id"] == "e2" end)
    # 4 total: e1 + stop1 (turn 1) + e2 + stop2 (turn 2) — no duplication.
    assert length(events2) == 4
  end

  test "send_event/2 on a :request_response session is unsupported" do
    {:ok, pid} =
      Session.start_link(ReqManagedAgents.FakeProviders.RequestResponse,
        handler: fn _, _, _ -> {:ok, ""} end,
        turns: [[%{"type" => "stop", "terminal" => :end_turn}]]
      )

    assert {:error, :unsupported} = Session.send_event(pid, %{"type" => "user.message"})
  end
end
