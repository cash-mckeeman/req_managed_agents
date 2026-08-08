defmodule ReqManagedAgents.Provisioner.NameTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Provisioner.Name
  alias ReqManagedAgents.Provisioner.Name.Policy

  @ac Policy.agent_core()

  test "composes base and digest" do
    assert Name.compose("rma-live-bedrock-harness", "38ca3140", @ac) ==
             "rma_live_bedrock_harness_38ca3140"
  end

  test "sanitizes to the policy charset and guarantees a leading letter" do
    assert Name.compose("9-live.agent", "38ca3140", @ac) =~ ~r/^[a-zA-Z][a-zA-Z0-9_]*$/
  end

  test "never exceeds the policy limit" do
    long = String.duplicate("verylongsegment", 8)
    assert String.length(Name.compose(long, "38ca3140", @ac)) <= 40
  end

  test "bases sharing a long common prefix stay distinct after truncation" do
    a = Name.compose(String.duplicate("a", 30) <> "harness", "38ca3140", @ac)
    b = Name.compose(String.duplicate("a", 30) <> "reattach", "38ca3140", @ac)
    refute a == b
  end

  test "the content digest survives truncation intact" do
    long = String.duplicate("z", 90)
    assert String.ends_with?(Name.compose(long, "38ca3140", @ac), "_38ca3140")
  end

  test "CMA policy leaves ordinary names untouched" do
    cma = Policy.claude_managed_agents()
    assert Name.compose("rma-v02-rtc", "38ca3140", cma) == "rma-v02-rtc_38ca3140"
  end
end
