defmodule ReqManagedAgents.AgentCoreTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.AgentCore

  test "drives a one-tool round trip: tool_use turn → handler → resume → end_turn" do
    test_pid = self()

    # A handler that echoes; this is exactly ManagedAgents.Tool.handler/1's shape.
    handler = fn "echo", %{"text" => t}, _ctx -> {:ok, "echoed: #{t}"} end

    # Stub two invokes: first returns a tool_use turn, second (the resume) ends the turn.
    invoke_fun = fn inv ->
      send(test_pid, {:invoke, inv})

      case inv[:messages] |> List.last() do
        # initial user message → emit a tool_use turn
        %{"role" => "user", "content" => [%{"text" => "begin"}]} ->
          {:ok,
           [
             %{
               "contentBlockStart" => %{
                 "contentBlockIndex" => 0,
                 "start" => %{"toolUse" => %{"toolUseId" => "tu_1", "name" => "echo"}}
               }
             },
             %{
               "contentBlockDelta" => %{
                 "contentBlockIndex" => 0,
                 "delta" => %{"toolUse" => %{"input" => "{\"text\":\"hi\"}"}}
               }
             },
             %{"messageStop" => %{"stopReason" => "tool_use"}}
           ]}

        # resume carrying the toolResult → end the turn with text
        %{"role" => "user", "content" => [%{"toolResult" => _}]} ->
          {:ok,
           [
             %{
               "contentBlockDelta" => %{
                 "contentBlockIndex" => 0,
                 "delta" => %{"text" => "all done."}
               }
             },
             %{"messageStop" => %{"stopReason" => "end_turn"}}
           ]}
      end
    end

    assert {:ok, run} =
             AgentCore.invoke_to_completion(
               handler: handler,
               context: %{},
               harness_id: "ba",
               runtime_session_id: "s1",
               prompt: "begin",
               invoke_fun: invoke_fun,
               timeout: 5_000
             )

    assert run.terminal == :end_turn
    assert run.stop_reason == "end_turn"

    # the resume invoke carried BOTH the assistant toolUse and the user toolResult (strict contract)
    assert_received {:invoke, _first}
    assert_received {:invoke, resume}
    roles = Enum.map(resume[:messages], & &1["role"])
    assert "assistant" in roles and "user" in roles
  end

  test "terminates on a normal stop with no tools" do
    invoke_fun = fn _ -> {:ok, [%{"messageStop" => %{"stopReason" => "end_turn"}}]} end

    assert {:ok, %{terminal: :end_turn}} =
             AgentCore.invoke_to_completion(
               handler: fn _, _, _ -> {:ok, ""} end,
               context: %{},
               harness_id: "ba",
               runtime_session_id: "s1",
               prompt: "begin",
               invoke_fun: invoke_fun
             )
  end
end
