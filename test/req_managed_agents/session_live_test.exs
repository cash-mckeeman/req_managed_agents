defmodule ReqManagedAgents.SessionLiveTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Session2
  alias ReqManagedAgents.FakeProviders.Streaming

  @ra [%{"type" => "tool", "id" => "t1", "name" => "echo", "input" => %{"x" => 1}},
       %{"type" => "stop", "terminal" => :requires_action}]
  @done [%{"type" => "stop", "terminal" => :end_turn}]

  test "start_link drives to a terminal, notifies, stays alive, and accepts a follow-up message" do
    test = self()
    handler = fn name, input, _ctx -> send(test, {:tool, name, input}); {:ok, "r"} end

    # kickoff → @ra (requires_action) → resume → @done (end_turn); then message → @done.
    {:ok, pid} =
      Session2.start_link(Streaming, handler: handler, notify: self(), turns: [@ra, @done, @done])

    assert_receive {:managed_agents_session, :end_turn}, 1000
    assert_received {:tool, "echo", %{"x" => 1}}
    assert Process.alive?(pid)

    Session2.message(pid, "again")
    assert_receive {:managed_agents_session, :end_turn}, 1000
    assert Process.alive?(pid)
  end

  test "a module handler's handle_event/2 receives every raw event" do
    defmodule EH do
      def handle_tool_call(_n, _i, _c), do: {:ok, "ok"}
      def handle_event(ev, test), do: send(test, {:saw, ev["type"]})
    end

    {:ok, _pid} = Session2.start_link(Streaming, handler: EH, context: self(), turns: [@done])
    assert_receive {:saw, "stop"}, 1000
  end
end
