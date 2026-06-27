defmodule ReqManagedAgents.ProfileTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Profile

  describe ":anthropic (identity)" do
    test "tool_use name/input read from top-level fields" do
      ev = %{"type" => "agent.custom_tool_use", "id" => "e1", "name" => "echo", "input" => %{"x" => 1}}
      assert {"echo", %{"x" => 1}} = Profile.tool_use(:anthropic, ev)
    end

    test "events stream path" do
      assert Profile.events_stream_path(:anthropic, "sess_1") == "/v1/sessions/sess_1/stream"
    end
  end

  describe ":jido (the 4 spike remaps)" do
    test "tool_use name/input nested under content[0]/payload" do
      ev = %{"type" => "agent.custom_tool_use", "id" => "e1", "content" => [%{"name" => "echo", "payload" => %{"x" => 1}}]}
      assert {"echo", %{"x" => 1}} = Profile.tool_use(:jido, ev)
    end

    test "events stream path is /events/stream" do
      assert Profile.events_stream_path(:jido, "sess_1") == "/v1/sessions/sess_1/events/stream"
    end

    test "status_idle with null stop_reason terminates only after an agent event was seen" do
      idle = %{"type" => "session.status_idle", "stop_reason" => nil}
      assert Profile.terminal?(:jido, idle, false) == false
      assert Profile.terminal?(:jido, idle, true) == :end_turn
    end
  end
end
