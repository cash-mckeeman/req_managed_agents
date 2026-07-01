defmodule ReqManagedAgents.ProviderTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.{Provider, ToolResult}

  test "declares the shared + invocation callbacks" do
    callbacks = Provider.behaviour_info(:callbacks)

    for cb <- [
          {:mode, 0},
          {:open, 2},
          {:kickoff_input, 1},
          {:user_input, 1},
          {:resume_input, 2},
          {:normalize, 1},
          {:poll_turn, 2},
          {:push_input, 2},
          {:turn_boundary?, 1}
        ] do
      assert cb in callbacks, "missing callback #{inspect(cb)}"
    end
  end

  test "result_of/2 extracts a %ToolResult{} from a Tools.run wire event" do
    wire = %{
      "type" => "user.custom_tool_result",
      "custom_tool_use_id" => "tu_1",
      "content" => [%{"type" => "text", "text" => "echoed: hi"}],
      "is_error" => false
    }

    assert %ToolResult{tool_use_id: "tu_1", text: "echoed: hi", is_error: false} =
             Provider.result_of("tu_1", wire)
  end

  test "result_of/2 defaults missing text to \"\" and treats is_error strictly" do
    assert %ToolResult{tool_use_id: "tu_2", text: "", is_error: true} =
             Provider.result_of("tu_2", %{"is_error" => true})
  end
end
