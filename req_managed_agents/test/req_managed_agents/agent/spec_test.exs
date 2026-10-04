defmodule ReqManagedAgents.Agent.SpecTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Agent.Spec

  @attrs %{
    name: "analyst",
    system_prompt: "You analyze.",
    tools: [%{"name" => "lookup", "description" => "d", "input_schema" => %{"type" => "object"}}],
    terminal_tool: "submit",
    model_config: "claude-opus-4-8"
  }

  test "new/1 coerces a map, defaulting optional fields" do
    assert {:ok, %Spec{name: "analyst", system_prompt: "You analyze.", terminal_tool: "submit"}} =
             Spec.new(@attrs)

    assert {:ok, %Spec{terminal_tool: nil, tools: []}} =
             Spec.new(%{name: "a", system_prompt: "s", model_config: "m"})
  end

  test "new/1 passes an existing %Spec{} through, rejects non-maps and missing required fields" do
    {:ok, spec} = Spec.new(@attrs)
    assert {:ok, ^spec} = Spec.new(spec)
    assert {:error, :invalid_agent_spec} = Spec.new(%{name: "a"})
    assert {:error, :invalid_agent_spec} = Spec.new("nope")
  end

  test "digest/1 is 8 lowercase hex, content-addressed and name-independent" do
    {:ok, a} = Spec.new(@attrs)
    {:ok, b} = Spec.new(%{@attrs | name: "different_name"})
    {:ok, c} = Spec.new(%{@attrs | system_prompt: "changed"})

    assert Spec.digest(a) =~ ~r/^[0-9a-f]{8}$/
    assert Spec.digest(a) == Spec.digest(b), "name must not affect the digest"
    assert Spec.digest(a) != Spec.digest(c), "content must affect the digest"
  end
end
