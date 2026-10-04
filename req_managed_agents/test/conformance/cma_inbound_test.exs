defmodule ReqManagedAgents.Conformance.CmaInboundTest do
  @moduledoc """
  Inbound conformance for Claude Managed Agents: replays a golden `session.*` event
  sequence through the REAL `ClaudeManagedAgents.normalize/1` and asserts the emitted
  `%TurnResult{}`. This proves RMA correctly folds real turn frames, not just that it
  can build requests. Goldens are 100% synthetic and shaped to match the event shapes
  `normalize/1` actually matches on (see `claude_managed_agents.ex` +
  `test/support/sse_fixtures.ex`).
  """
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Conformance.Corpus
  alias ReqManagedAgents.Providers.ClaudeManagedAgents
  alias ReqManagedAgents.{ToolUse, TurnResult}

  defp events(name), do: Corpus.load(:cma, :responses, name).json["events"]

  test "a golden end-turn frame sequence normalizes to :end_turn" do
    tr = ClaudeManagedAgents.normalize(events("turn_end_turn"))

    assert %TurnResult{terminal: :end_turn, stop_reason: %{"type" => "end_turn"}} = tr
  end

  test "a golden requires_action frame sequence normalizes to :requires_action with the custom tool use" do
    tr = ClaudeManagedAgents.normalize(events("turn_requires_action"))

    assert %TurnResult{
             terminal: :requires_action,
             stop_reason: %{"type" => "requires_action", "event_ids" => ["e1"]},
             custom_tool_uses: [%ToolUse{id: "e1", name: "get_weather", input: %{"city" => "SF"}}]
           } = tr
  end

  test "a golden terminated frame surfaces :terminated" do
    tr = ClaudeManagedAgents.normalize(events("turn_terminated"))

    assert %TurnResult{terminal: :terminated, stop_reason: %{"type" => "error"}} = tr
  end
end
