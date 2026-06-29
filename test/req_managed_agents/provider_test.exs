defmodule ReqManagedAgents.ProviderTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Provider

  test "declares the four provider callbacks" do
    callbacks = Provider.behaviour_info(:callbacks)
    assert {:decode, 1} in callbacks
    assert {:normalize, 1} in callbacks
    assert {:terminal, 1} in callbacks
    assert {:resume, 2} in callbacks
  end

  test "result_of/2 extracts a canonical custom_tool_result from a Tools.run wire event" do
    wire = %{
      "type" => "user.custom_tool_result",
      "custom_tool_use_id" => "tu_1",
      "content" => [%{"type" => "text", "text" => "echoed: hi"}],
      "is_error" => false
    }

    assert Provider.result_of("tu_1", wire) ==
             %{tool_use_id: "tu_1", text: "echoed: hi", is_error: false}
  end

  test "result_of/2 defaults missing text to \"\" and treats is_error truthiness strictly" do
    assert Provider.result_of("tu_2", %{"is_error" => true}) ==
             %{tool_use_id: "tu_2", text: "", is_error: true}
  end
end
