defmodule ReqManagedAgents.EventTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Event

  test "user_message/1 builds a text user.message" do
    assert Event.user_message("hi") == %{
             "type" => "user.message",
             "content" => [%{"type" => "text", "text" => "hi"}]
           }
  end

  test "custom_tool_result/2 builds a success result" do
    assert Event.custom_tool_result("u1", "ok") == %{
             "type" => "user.custom_tool_result",
             "custom_tool_use_id" => "u1",
             "content" => [%{"type" => "text", "text" => "ok"}],
             "is_error" => false
           }
  end

  test "custom_tool_result/3 marks errors" do
    ev = Event.custom_tool_result("u1", "boom", is_error: true)
    assert ev["is_error"] == true
  end

  test "tool_confirmation/2 builds allow/deny" do
    assert Event.tool_confirmation("t1", :allow)["result"] == "allow"
    assert Event.tool_confirmation("t1", :deny)["result"] == "deny"
  end

  test "classify/1 maps idle stop reasons" do
    assert Event.classify(%{
             "type" => "session.status_idle",
             "stop_reason" => %{"type" => "end_turn"}
           }) == :end_turn

    assert Event.classify(%{
             "type" => "session.status_idle",
             "stop_reason" => %{"type" => "requires_action", "event_ids" => ["e1"]}
           }) == :requires_action

    assert Event.classify(%{
             "type" => "session.status_idle",
             "stop_reason" => %{"type" => "retries_exhausted"}
           }) == :retries_exhausted
  end

  test "classify/1 maps terminal/error/unknown" do
    assert Event.classify(%{"type" => "session.status_terminated"}) == :terminated
    assert Event.classify(%{"type" => "session.error", "error" => %{}}) == :error
    assert Event.classify(%{"type" => "agent.message"}) == :other

    assert Event.classify(%{
             "type" => "session.status_idle",
             "stop_reason" => %{"type" => "weird"}
           }) == :unknown_idle
  end
end
