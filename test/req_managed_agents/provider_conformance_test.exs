defmodule ReqManagedAgents.ProviderConformanceTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Providers.{BedrockAgentCore, ClaudeManagedAgents}

  # Every provider implements the shared callbacks; each mode adds its own.
  @shared [{:mode, 0}, {:open, 2}, {:kickoff_input, 1}, {:user_input, 1}, {:resume_input, 2}, {:normalize, 1}]

  test "BedrockAgentCore is a complete :request_response provider" do
    Code.ensure_loaded!(BedrockAgentCore)
    assert BedrockAgentCore.mode() == :request_response

    for {f, a} <- @shared ++ [{:poll_turn, 2}] do
      assert function_exported?(BedrockAgentCore, f, a), "BedrockAgentCore missing #{f}/#{a}"
    end
  end

  test "ClaudeManagedAgents is a complete :streaming provider" do
    Code.ensure_loaded!(ClaudeManagedAgents)
    assert ClaudeManagedAgents.mode() == :streaming

    for {f, a} <- @shared ++ [{:push_input, 2}, {:turn_boundary?, 1}, {:reconnect, 3}] do
      assert function_exported?(ClaudeManagedAgents, f, a), "ClaudeManagedAgents missing #{f}/#{a}"
    end
  end

  test "both providers normalize to the same canonical turn_outcome keys" do
    keys = [:terminal, :stop_reason, :custom_tool_uses, :server_tool_uses, :text, :events]

    bedrock = BedrockAgentCore.normalize([%{"messageStop" => %{"stopReason" => "end_turn"}}])
    claude = ClaudeManagedAgents.normalize([%{"type" => "session.status_idle", "stop_reason" => %{"type" => "end_turn"}}])

    assert Enum.sort(Map.keys(bedrock)) == Enum.sort(keys)
    assert Enum.sort(Map.keys(claude)) == Enum.sort(keys)
    assert bedrock.terminal == :end_turn and claude.terminal == :end_turn
  end
end
