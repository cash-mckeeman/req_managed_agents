defmodule ReqManagedAgents.Acceptance.RunnerTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Acceptance.{Assertion, Report}

  test "required assertions cannot pass vacuously or by duplication" do
    assert {:ok, passed} = Assertion.new("native_activity", :passed, ["stream:r1"])
    assert Report.outcome(["native_activity"], [passed]) == :passed
    assert Report.outcome(["native_activity"], []) == :failed
    assert Report.outcome(["native_activity"], [passed, passed]) == :failed
    assert Report.outcome([], []) == :failed
    assert Report.outcome(["other"], [passed]) == :failed
  end

  test "missing or partial native evidence cannot pass" do
    assert {:ok, missing} = Assertion.new("native_activity", :inconclusive, [])
    assert Report.outcome(["native_activity"], [missing]) == :inconclusive
    assert {:error, :invalid_assertion} = Assertion.new("native_activity", :passed, [])
  end
end
