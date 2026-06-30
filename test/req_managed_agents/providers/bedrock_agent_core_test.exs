defmodule ReqManagedAgents.Providers.BedrockAgentCoreTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Providers.BedrockAgentCore, as: AgentCore

  defp start_block(idx, id, name) do
    %{"contentBlockStart" => %{"contentBlockIndex" => idx, "start" => %{"toolUse" => %{"toolUseId" => id, "name" => name}}}}
  end

  defp delta(idx, frag) do
    %{"contentBlockDelta" => %{"contentBlockIndex" => idx, "delta" => %{"toolUse" => %{"input" => frag}}}}
  end

  defp tool_stop, do: %{"messageStop" => %{"stopReason" => "tool_use"}}

  test "normalize/1 maps a tool_use turn to canonical custom_tool_uses + :requires_action" do
    events = [start_block(0, "tu_1", "echo"), delta(0, ~s({"text":"hi"})), tool_stop()]

    assert AgentCore.normalize(events) == %{
             terminal: :requires_action,
             stop_reason: "tool_use",
             custom_tool_uses: [%{id: "tu_1", name: "echo", input: %{"text" => "hi"}}],
             server_tool_uses: [],
             text: ""
           }
  end

  test "normalize/1 maps a normal stop to :end_turn with no custom_tool_uses" do
    events = [
      %{"contentBlockDelta" => %{"contentBlockIndex" => 0, "delta" => %{"text" => "done."}}},
      %{"messageStop" => %{"stopReason" => "end_turn"}}
    ]

    assert %{terminal: :end_turn, stop_reason: "end_turn", custom_tool_uses: [], text: "done."} =
             AgentCore.normalize(events)
  end

  test "terminal/1 collapses to the canonical three atoms" do
    assert AgentCore.terminal("end_turn") == :end_turn
    assert AgentCore.terminal("stop_sequence") == :end_turn
    assert AgentCore.terminal("tool_use") == :requires_action
    assert AgentCore.terminal("max_tokens") == :terminated
    assert AgentCore.terminal("guardrail_intervened") == :terminated
    assert AgentCore.terminal("something_new") == :terminated
    assert AgentCore.terminal(nil) == :terminated
  end

  test "MIM-52 regression: a reused contentBlockIndex recovers BOTH distinct tools" do
    events = [start_block(0, "tu_A", "f"), start_block(0, "tu_B", "g"), tool_stop()]
    ids = Enum.map(AgentCore.normalize(events).custom_tool_uses, & &1.id)
    assert ids == ["tu_A", "tu_B"]
  end

  test "server-side exclusion: unrecognized content events never enter custom_tool_uses" do
    events = [
      %{"contentBlockStart" => %{"contentBlockIndex" => 0, "start" => %{"someServerTool" => %{"name" => "web_search"}}}},
      start_block(1, "tu_1", "echo"),
      delta(1, ~s({})),
      tool_stop()
    ]

    assert [%{id: "tu_1"}] = AgentCore.normalize(events).custom_tool_uses
  end

  test "resume/2 produces the strict two-message Converse resume" do
    uses = [%{id: "tu_1", name: "echo", input: %{"text" => "hi"}}]
    results = [%{tool_use_id: "tu_1", text: "echoed: hi", is_error: false}]

    assert [%{"role" => "assistant", "content" => [%{"toolUse" => tu}]}, user] =
             AgentCore.resume(uses, results)

    assert tu == %{"toolUseId" => "tu_1", "name" => "echo", "input" => %{"text" => "hi"}}
    assert get_in(user, ["content", Access.at(0), "toolResult", "status"]) == "success"
  end

  test "implements the Provider behaviour" do
    Code.ensure_loaded!(AgentCore)
    callbacks = ReqManagedAgents.Provider.behaviour_info(:callbacks)
    for cb <- callbacks, do: assert function_exported?(AgentCore, elem(cb, 0), elem(cb, 1))
  end
end
