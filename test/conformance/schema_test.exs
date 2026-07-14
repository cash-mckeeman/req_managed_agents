defmodule ReqManagedAgents.Conformance.SchemaTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Conformance.Schema

  @shape %{
    "required" => ["name", "executionRoleArn", "model"],
    "members" => %{
      "name" => %{"type" => "string"},
      "executionRoleArn" => %{"type" => "string"},
      "model" => %{"type" => "string"},
      "tools" => %{"type" => "list"}
    }
  }

  test "valid body passes" do
    assert :ok ==
             Schema.validate(
               %{
                 "name" => "h",
                 "executionRoleArn" => "arn:...",
                 "model" => "claude",
                 "tools" => []
               },
               @shape
             )
  end

  test "missing required field is reported" do
    assert {:error, v} = Schema.validate(%{"name" => "h", "model" => "c"}, @shape)
    assert {:missing, "executionRoleArn"} in v
  end

  test "wrong type is reported" do
    assert {:error, v} =
             Schema.validate(%{"name" => "h", "executionRoleArn" => "a", "model" => 42}, @shape)

    assert {:type, "model", "string"} in v
  end

  test "unknown key is reported (catches upstream ADDING a field we don't model)" do
    assert {:error, v} =
             Schema.validate(
               %{"name" => "h", "executionRoleArn" => "a", "model" => "c", "newFangled" => true},
               @shape
             )

    assert {:unknown, "newFangled"} in v
  end

  test "botocore structure/long types are enforced, not silently accepted" do
    shape = %{
      "required" => [],
      "members" => %{"config" => %{"type" => "structure"}, "n" => %{"type" => "long"}}
    }

    assert {:error, v} = Schema.validate(%{"config" => 42, "n" => "nope"}, shape)
    assert {:type, "config", "structure"} in v
    assert {:type, "n", "long"} in v
    assert :ok == Schema.validate(%{"config" => %{}, "n" => 5}, shape)
  end

  test "an unmodeled type in our shape slice is a violation, not a silent pass" do
    shape = %{"required" => [], "members" => %{"x" => %{"type" => "bogustype"}}}
    assert {:error, [{:type, "x", "bogustype"}]} = Schema.validate(%{"x" => 1}, shape)
  end
end
