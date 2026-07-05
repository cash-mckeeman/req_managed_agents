defmodule ReqManagedAgents.OutcomeTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Outcome

  test "new/1 passes an existing %Outcome{} through unchanged" do
    o = %Outcome{description: "d", rubric: "r", max_iterations: 2}
    assert {:ok, ^o} = Outcome.new(o)
  end

  test "new/1 coerces an atom-keyed map, defaulting max_iterations to nil" do
    assert {:ok, %Outcome{description: "d", rubric: "r", max_iterations: nil}} =
             Outcome.new(%{description: "d", rubric: "r"})

    assert {:ok, %Outcome{max_iterations: 5}} =
             Outcome.new(%{description: "d", rubric: "r", max_iterations: 5})
  end

  test "new/1 rejects non-binary fields, string keys, and non-maps" do
    assert {:error, :invalid_outcome} = Outcome.new(%{description: "d"})
    assert {:error, :invalid_outcome} = Outcome.new(%{"description" => "d", "rubric" => "r"})
    assert {:error, :invalid_outcome} = Outcome.new(%{description: 1, rubric: "r"})
    assert {:error, :invalid_outcome} = Outcome.new("nope")
  end
end
