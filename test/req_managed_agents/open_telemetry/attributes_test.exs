defmodule ReqManagedAgents.OpenTelemetry.AttributesTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.OpenTelemetry.Attributes

  test "invoke_agent sets operation, provider, conversation id" do
    out = Attributes.invoke_agent(%{session_id: "s1"})
    assert out["gen_ai.operation.name"] == "invoke_agent"
    assert out["gen_ai.provider.name"] == "anthropic"
    assert out["gen_ai.conversation.id"] == "s1"
  end

  test "chat carries usage tokens when present (string-keyed Anthropic usage)" do
    out =
      Attributes.chat(%{session_id: "s1", usage: %{"input_tokens" => 10, "output_tokens" => 5}})

    assert out["gen_ai.operation.name"] == "chat"
    assert out["gen_ai.provider.name"] == "anthropic"
    assert out["gen_ai.usage.input_tokens"] == 10
    assert out["gen_ai.usage.output_tokens"] == 5
  end

  test "chat omits usage keys when absent" do
    out = Attributes.chat(%{session_id: "s1"})
    refute Map.has_key?(out, "gen_ai.usage.input_tokens")
  end

  test "tool sets execute_tool + tool name; no input/result content" do
    out = Attributes.tool(%{session_id: "s1", tool: "calculator", is_error: false})
    assert out["gen_ai.operation.name"] == "execute_tool"
    assert out["gen_ai.tool.name"] == "calculator"
    assert out["gen_ai.conversation.id"] == "s1"
    refute Enum.any?(Map.keys(out), &String.contains?(&1, "input"))
  end

  test "tool marks error.type when is_error" do
    out = Attributes.tool(%{session_id: "s1", tool: "calculator", is_error: true})
    assert out["error.type"] == "tool_error"
  end

  test "terminal maps the terminal atom to finish_reasons" do
    out = Attributes.terminal(%{session_id: "s1", terminal: :end_turn})
    assert out["gen_ai.response.finish_reasons"] == ["end_turn"]
    assert out["gen_ai.conversation.id"] == "s1"
  end

  test "mappers never raise on sparse metadata" do
    assert Attributes.invoke_agent(%{}) |> is_map()
    assert Attributes.chat(%{}) |> is_map()
    assert Attributes.tool(%{}) |> is_map()
    assert Attributes.terminal(%{}) |> is_map()
  end
end
