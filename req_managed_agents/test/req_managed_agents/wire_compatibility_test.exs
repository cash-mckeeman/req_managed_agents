defmodule ReqManagedAgents.WireCompatibilityTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.{Budget, Consolidate, Event, Profile, Provider}

  test "published event builders preserve default and explicit option arities" do
    assert Event.user_message("hi") == %{
             "type" => "user.message",
             "content" => [%{"type" => "text", "text" => "hi"}]
           }

    assert Event.define_outcome("d", "r") == Event.define_outcome("d", "r", [])
    result = Event.custom_tool_result("u", "ok")
    assert result == Event.custom_tool_result("u", "ok", [])

    assert %ReqManagedAgents.ToolResult{tool_use_id: "u", text: "ok", is_error: false} =
             Provider.result_of("u", result)

    assert Event.custom_tool_result("u", "bad", is_error: true)["is_error"]
    assert Event.tool_confirmation("u", :deny)["result"] == "deny"
    assert Event.classify(%{"type" => "session.status_terminated"}) == :terminated
  end

  test "published profile and reconnect helpers remain callable" do
    assert Profile.tool_use(:anthropic, %{"name" => "echo", "input" => %{}}) == {"echo", %{}}
    assert Profile.events_stream_path(:jido, "s") == "/v1/sessions/s/events/stream"
    idle = %{"type" => "session.status_idle", "stop_reason" => nil}
    refute Profile.terminal?(:jido, idle, false)
    assert Profile.terminal?(:jido, idle, true) == :end_turn
    use_event = %{"id" => "u", "type" => "agent.custom_tool_use"}
    assert Consolidate.unanswered_tool_uses([use_event]) == [use_event]
    assert Consolidate.dedupe([use_event], MapSet.new()) == {[use_event], MapSet.new(["u"])}
    pending = %{"type" => "requires_action", "event_ids" => ["u"]}

    assert Consolidate.pending_requires_action([
             %{"type" => "session.status_idle", "stop_reason" => pending}
           ]) == pending
  end

  test "published budget operations preserve confirmation checks" do
    budget = %Budget{max_list_cost_cents: 5}

    assert Budget.to_wire(budget) == %{
             type: "limit",
             max_list_cost: %{amount: "5", currency: "USD"}
           }

    assert Budget.confirmed?(budget, %{
             "type" => "limit",
             "max_list_cost" => %{"amount" => "5", "currency" => "USD"}
           })

    for malformed <- [nil, %{}, %{"type" => "limit", "max_list_cost" => nil}] do
      refute Budget.confirmed?(budget, malformed)
      refute ReqManagedAgents.Providers.ClaudeManagedAgents.Budget.confirmed?(budget, malformed)
    end
  end
end
