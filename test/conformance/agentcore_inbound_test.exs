defmodule ReqManagedAgents.Conformance.AgentcoreInboundTest do
  @moduledoc """
  Inbound conformance for AgentCore: replays a golden Converse event sequence
  (the decoded frames `invoke_harness` hands `normalize/1`) through the REAL
  `BedrockAgentCore.normalize/1` and asserts the emitted `%TurnResult{}`. This
  proves RMA correctly parses real turn frames, not just that it can build
  requests. Goldens are 100% synthetic and shaped to match `Converse.reduce_event/2`
  byte-for-byte (see `converse.ex`) so this exercises the real fold, not a stand-in.

  Schema-validating the streamed Converse frames themselves is out of scope —
  those are `aws_event_stream` eventstream frames, not a botocore JSON model.
  """
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Conformance.Corpus
  alias ReqManagedAgents.Providers.BedrockAgentCore
  alias ReqManagedAgents.{ToolUse, TurnResult}

  defp events(name), do: Corpus.load(:agentcore, :responses, name).json["events"]

  test "a golden end-turn frame sequence normalizes to :end_turn" do
    tr = BedrockAgentCore.normalize(events("turn_end_turn"))

    assert %TurnResult{terminal: :end_turn, stop_reason: "end_turn", text: "Hello, world!"} = tr
  end

  test "a golden tool-use frame sequence normalizes to :requires_action with the custom tool use" do
    tr = BedrockAgentCore.normalize(events("turn_requires_action"))

    assert %TurnResult{
             terminal: :requires_action,
             stop_reason: "tool_use",
             custom_tool_uses: [
               %ToolUse{id: "tooluse_abc123", name: "get_weather", input: %{"location" => "NYC"}}
             ]
           } = tr
  end

  test "a golden terminated frame surfaces :terminated" do
    tr = BedrockAgentCore.normalize(events("turn_terminated"))

    assert %TurnResult{terminal: :terminated, stop_reason: "max_tokens"} = tr
  end
end
