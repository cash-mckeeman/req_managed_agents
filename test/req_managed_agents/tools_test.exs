defmodule ReqManagedAgents.ToolsTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Tools

  defmodule H do
    @behaviour ReqManagedAgents.Handler
    @impl true
    def handle_tool_call("ok", _i, _c), do: {:ok, "fine"}
    def handle_tool_call("err", _i, _c), do: {:error, "bad"}
    def handle_tool_call("boom", _i, _c), do: raise("kaboom")
  end

  test "run/5 builds a success result" do
    assert %{
             "type" => "user.custom_tool_result",
             "custom_tool_use_id" => "u1",
             "is_error" => false
           } =
             Tools.run(H, "u1", "ok", %{}, nil)
  end

  test "run/5 marks {:error, _} as is_error" do
    assert %{"is_error" => true} = Tools.run(H, "u1", "err", %{}, nil)
  end

  test "run/5 catches a raising handler into an is_error result" do
    ev = Tools.run(H, "u1", "boom", %{}, nil)
    assert ev["is_error"] == true
  end
end
