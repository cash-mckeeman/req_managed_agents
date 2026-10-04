defmodule ReqManagedAgents.ConsolidateTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Consolidate

  test "dedupe/2 returns only unseen events and updates the seen set" do
    seen = MapSet.new(["e1"])
    events = [%{"id" => "e1"}, %{"id" => "e2"}, %{"id" => "e3"}]
    {fresh, seen2} = Consolidate.dedupe(events, seen)
    assert Enum.map(fresh, & &1["id"]) == ["e2", "e3"]
    assert MapSet.equal?(seen2, MapSet.new(["e1", "e2", "e3"]))
  end

  test "dedupe/2 is idempotent across a replayed batch" do
    events = [%{"id" => "e1"}, %{"id" => "e2"}]
    {_, seen} = Consolidate.dedupe(events, MapSet.new())
    {fresh2, _} = Consolidate.dedupe(events, seen)
    assert fresh2 == []
  end

  test "unanswered_tool_uses/1 finds custom_tool_use without a matching result" do
    history = [
      %{"type" => "agent.custom_tool_use", "id" => "u1", "name" => "a", "input" => %{}},
      %{"type" => "agent.custom_tool_use", "id" => "u2", "name" => "b", "input" => %{}},
      %{"type" => "user.custom_tool_result", "custom_tool_use_id" => "u1"}
    ]

    assert [%{"id" => "u2"}] = Consolidate.unanswered_tool_uses(history)
  end

  test "pending_requires_action/1 returns the last unresolved requires_action" do
    history = [
      %{
        "type" => "session.status_idle",
        "stop_reason" => %{"type" => "requires_action", "event_ids" => ["u1"]}
      },
      %{"type" => "session.status_idle", "stop_reason" => %{"type" => "end_turn"}}
    ]

    assert Consolidate.pending_requires_action(history) == nil

    history2 = [
      %{
        "type" => "session.status_idle",
        "stop_reason" => %{"type" => "requires_action", "event_ids" => ["u9"]}
      }
    ]

    assert %{"event_ids" => ["u9"]} = Consolidate.pending_requires_action(history2)
  end
end
