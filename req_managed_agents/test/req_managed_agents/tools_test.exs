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

  test "execute/6 builds a success result" do
    assert %ReqManagedAgents.ToolResult{
             tool_use_id: "u1",
             text: "fine",
             is_error: false
           } =
             Tools.execute(H, "u1", "ok", %{}, nil, %ReqManagedAgents.SessionInfo{})
  end

  test "execute/6 marks {:error, _} as is_error" do
    assert %ReqManagedAgents.ToolResult{tool_use_id: "u1", text: "bad", is_error: true} =
             Tools.execute(H, "u1", "err", %{}, nil, %ReqManagedAgents.SessionInfo{})
  end

  test "execute/6 catches a raising handler into an is_error result" do
    ev = Tools.execute(H, "u1", "boom", %{}, nil, %ReqManagedAgents.SessionInfo{})
    assert ev.is_error == true
    assert ev.text == "tool error: %RuntimeError{message: \"kaboom\"}"
  end

  test "execute/6 accepts a bare 3-arity fn handler (not only a module)" do
    fun = fn name, input, _ctx -> {:ok, "ran:#{name}:#{inspect(input)}"} end
    ev = Tools.execute(fun, "u1", "echo", %{"x" => 1}, nil, %ReqManagedAgents.SessionInfo{})
    assert %ReqManagedAgents.ToolResult{} = ev
    assert ev.tool_use_id == "u1"
    assert ev.is_error == false
    text = ev.text
    assert text =~ "ran:echo"
  end

  test "execute/6 fn handler returning {:error, _} produces is_error result" do
    fun = fn _name, _input, _ctx -> {:error, "fn-error"} end
    ev = Tools.execute(fun, "u2", "tool", %{}, nil, %ReqManagedAgents.SessionInfo{})
    assert ev.is_error == true
    text = ev.text
    assert text == "fn-error"
  end

  test "execute/7 preserves telemetry and handles a four argument handler" do
    parent = self()
    key = {__MODULE__, make_ref()}

    :telemetry.attach(
      key,
      [:req_managed_agents, :tool, :stop],
      fn _, _, meta, _ -> send(parent, {:tool_stop, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(key) end)
    info = %ReqManagedAgents.SessionInfo{session_id: "s"}
    fun = fn "ok", %{}, :context, ^info -> {:ok, "four"} end

    assert %ReqManagedAgents.ToolResult{text: "four", is_error: false} =
             Tools.execute(fun, "u", "ok", %{}, :context, info, %{session_id: "s"})

    assert_receive {:tool_stop, %{tool: "ok", is_error: false, session_id: "s"}}
    thrower = fn _, _, _ -> throw(:broken) end

    assert %ReqManagedAgents.ToolResult{text: "tool throw: :broken", is_error: true} =
             Tools.execute(thrower, "u", "throw", %{}, nil, info, %{session_id: "s"})

    assert_receive {:tool_stop, %{tool: "throw", is_error: true, session_id: "s"}}
  end
end
