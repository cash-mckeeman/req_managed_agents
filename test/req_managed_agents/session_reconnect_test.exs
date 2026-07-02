defmodule ReqManagedAgents.SessionReconnectTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Session
  alias ReqManagedAgents.FakeProviders.ReconnectingStreaming

  test "a live streaming session reconnects on a stream drop and re-drives unanswered tool calls" do
    test = self()

    handler = fn name, input, _ctx ->
      send(test, {:tool, name, input})
      {:ok, "r"}
    end

    # kickoff push is dropped → the Session reconnects → reconnect/3 surfaces the unanswered
    # tool (t1) → the Session re-runs it locally and resumes → the next turn ends the run.
    {:ok, pid} =
      Session.start_link(ReconnectingStreaming,
        handler: handler,
        notify: self(),
        pending: [%{id: "t1", name: "echo", input: %{"x" => 1}}],
        turns: [[%{"type" => "stop", "terminal" => :end_turn}]]
      )

    assert_receive {:tool, "echo", %{"x" => 1}}, 2000

    assert_receive {:managed_agents_session,
                    %ReqManagedAgents.SessionResult{terminal: :end_turn}},
                   2000

    assert Process.alive?(pid)
  end

  test "a synchronous run/2 does NOT reconnect — a stream error surfaces as {:error, _}" do
    # ReconnectingStreaming drops the first push; under run/2 (a sync caller) that must surface.
    assert {:error, :stream_dropped} =
             Session.run(ReconnectingStreaming,
               handler: fn _, _, _ -> {:ok, "x"} end,
               pending: [],
               turns: []
             )
  end
end
