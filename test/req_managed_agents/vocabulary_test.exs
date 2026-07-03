defmodule ReqManagedAgents.VocabularyTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.{SessionResult, ToolResult, ToolUse, TurnResult, Usage}

  test "structs construct with the documented defaults and encode to JSON" do
    assert %Usage{input_tokens: 0, output_tokens: 0, raw: []} = %Usage{}

    assert %ToolUse{id: "t1", name: "echo", input: %{}} = %ToolUse{
             id: "t1",
             name: "echo",
             input: %{}
           }

    assert %ToolResult{tool_use_id: "t1", text: "", is_error: false} = %ToolResult{
             tool_use_id: "t1"
           }

    assert %TurnResult{terminal: :terminated, custom_tool_uses: [], usage: nil} = %TurnResult{}
    assert %SessionResult{turns: 0, usage: %Usage{}} = %SessionResult{}

    for s <- [
          %Usage{},
          %ToolUse{id: "1", name: "n", input: %{}},
          %ToolResult{tool_use_id: "1"},
          %TurnResult{},
          %SessionResult{}
        ] do
      assert {:ok, json} = Jason.encode(s)
      assert is_binary(json)
    end
  end
end
