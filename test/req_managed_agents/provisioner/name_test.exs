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

  describe "at the fit boundary" do
    # The AgentCore budget for the base is 40 - len(digest) - 1 = 31 bytes: the
    # last width that survives whole, and the first that must be hashed.
    test "a base of exactly the budget is kept whole" do
      base = String.duplicate("a", 31)
      composed = Name.compose(base, "38ca3140", @ac)

      assert composed == base <> "_38ca3140"
      assert byte_size(composed) == 40
    end

    test "a base one byte over the budget is hashed and still fits" do
      base = String.duplicate("a", 32)
      composed = Name.compose(base, "38ca3140", @ac)

      refute composed == base <> "_38ca3140"
      assert byte_size(composed) == 40
      assert composed =~ ~r/^[a-zA-Z][a-zA-Z0-9_]{0,39}$/
      assert String.ends_with?(composed, "_38ca3140")
    end

    test "bases at 31 and 32 do not collapse onto each other" do
      a = Name.compose(String.duplicate("a", 31), "38ca3140", @ac)
      b = Name.compose(String.duplicate("a", 32), "38ca3140", @ac)
      refute a == b
    end
  end

  test "a truncated multi-byte base stays valid UTF-8 and inside the byte budget" do
    # Only reachable on the permissive policy, where the sanitiser does not first
    # reduce the base to ASCII. Cutting on a raw byte boundary here would split a
    # character; slicing by grapheme would overrun the limit.
    cma = Policy.claude_managed_agents()

    # The leading ASCII byte is load-bearing: it makes the byte budget land in the
    # middle of a two-byte character rather than neatly between two.
    base = "a" <> String.duplicate("é", 200)
    refute String.valid?(binary_part(base, 0, 240)), "base must actually straddle the cut"

    composed = Name.compose(base, "38ca3140", cma)

    assert String.valid?(composed)
    assert byte_size(composed) <= 256
  end
end
