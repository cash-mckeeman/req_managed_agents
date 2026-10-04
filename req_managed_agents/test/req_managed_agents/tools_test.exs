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

  test "run/7 builds a success result" do
    assert %{
             "type" => "user.custom_tool_result",
             "custom_tool_use_id" => "u1",
             "is_error" => false
           } =
             Tools.run(H, "u1", "ok", %{}, nil, %ReqManagedAgents.SessionInfo{})
  end

  test "run/7 marks {:error, _} as is_error" do
    assert %{"is_error" => true} =
             Tools.run(H, "u1", "err", %{}, nil, %ReqManagedAgents.SessionInfo{})
  end

  test "run/7 catches a raising handler into an is_error result" do
    ev = Tools.run(H, "u1", "boom", %{}, nil, %ReqManagedAgents.SessionInfo{})
    assert ev["is_error"] == true
  end

  test "run/7 accepts a bare 3-arity fn handler (not only a module)" do
    fun = fn name, input, _ctx -> {:ok, "ran:#{name}:#{inspect(input)}"} end
    ev = Tools.run(fun, "u1", "echo", %{"x" => 1}, nil, %ReqManagedAgents.SessionInfo{})
    assert ev["type"] == "user.custom_tool_result"
    assert ev["custom_tool_use_id"] == "u1"
    assert ev["is_error"] == false
    text = ev["content"] |> List.first() |> Map.get("text")
    assert text =~ "ran:echo"
  end

  test "run/7 fn handler returning {:error, _} produces is_error result" do
    fun = fn _name, _input, _ctx -> {:error, "fn-error"} end
    ev = Tools.run(fun, "u2", "tool", %{}, nil, %ReqManagedAgents.SessionInfo{})
    assert ev["is_error"] == true
    text = ev["content"] |> List.first() |> Map.get("text")
    assert text == "fn-error"
  end
end
