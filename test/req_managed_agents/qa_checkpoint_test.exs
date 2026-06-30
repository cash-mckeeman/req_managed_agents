defmodule ReqManagedAgents.QaCheckpointTest do
  @moduledoc "Proves the QA-CHECKPOINT pass/fail gate is not vacuous: it catches divergence."
  use ExUnit.Case, async: true
  alias Mix.Tasks.ReqManagedAgents.QaCheckpoint

  defp fp(scenario, overrides \\ %{}) do
    Map.merge(
      %{
        "scenario" => scenario,
        "provider" => "bedrock",
        "result" => "ok",
        "terminal" => "end_turn",
        "stop_reason_type" => "end_turn",
        "tool_calls" => ["echo"],
        "n_final_events" => 4,
        "error" => nil,
        "stop_reason_raw_kind" => "string"
      },
      overrides
    )
  end

  test "identical fingerprints pass all scenarios" do
    fps = [fp("a"), fp("b")]
    c = QaCheckpoint.compare(fps, fps)
    assert c.pass == 2 and c.total == 2
  end

  test "a diverging compared field (different tool call) fails that scenario" do
    pr11 = [fp("a"), fp("b")]
    pr13 = [fp("a"), fp("b", %{"tool_calls" => ["WRONG"]})]
    c = QaCheckpoint.compare(pr11, pr13)
    assert c.pass == 1 and c.total == 2
    bad = Enum.find(c.scenarios, &(&1.name == "b"))
    assert {"tool_calls", ["echo"], ["WRONG"]} in bad.mismatches
  end

  test "a missing scenario on one side is a mismatch" do
    c = QaCheckpoint.compare([fp("a"), fp("b")], [fp("a")])
    assert c.pass == 1 and c.total == 2
  end

  test "stop_reason map→string is allow-listed, not a failure" do
    pr11 = [fp("a", %{"stop_reason_raw_kind" => "map"})]
    pr13 = [fp("a", %{"stop_reason_raw_kind" => "string"})]
    c = QaCheckpoint.compare(pr11, pr13)
    assert c.pass == 1 and c.total == 1
    assert {"a", "map", "string"} in c.allowlisted
  end
end
