defmodule ReqManagedAgents.ProviderConformanceTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Providers.{BedrockAgentCore, ClaudeManagedAgents}

  # Every provider implements the shared callbacks; each mode adds its own.
  @shared [
    {:mode, 0},
    {:open, 2},
    {:kickoff_input, 1},
    {:user_input, 1},
    {:resume_input, 2},
    {:normalize, 1},
    {:provision, 2}
  ]

  test "BedrockAgentCore is a complete :request_response provider" do
    Code.ensure_loaded!(BedrockAgentCore)
    assert BedrockAgentCore.mode() == :request_response

    for {f, a} <- @shared ++ [{:poll_turn, 2}] do
      assert function_exported?(BedrockAgentCore, f, a), "BedrockAgentCore missing #{f}/#{a}"
    end

    assert function_exported?(BedrockAgentCore, :teardown, 2),
           "BedrockAgentCore missing teardown/2"
  end

  test "ClaudeManagedAgents is a complete :streaming provider" do
    Code.ensure_loaded!(ClaudeManagedAgents)
    assert ClaudeManagedAgents.mode() == :streaming

    for {f, a} <- @shared ++ [{:push_input, 2}, {:turn_boundary?, 1}, {:reconnect, 3}] do
      assert function_exported?(ClaudeManagedAgents, f, a),
             "ClaudeManagedAgents missing #{f}/#{a}"
    end

    assert function_exported?(ClaudeManagedAgents, :teardown, 2),
           "ClaudeManagedAgents missing teardown/2"
  end

  test "both providers normalize to a %TurnResult{}" do
    bedrock = BedrockAgentCore.normalize([%{"messageStop" => %{"stopReason" => "end_turn"}}])

    claude =
      ClaudeManagedAgents.normalize([
        %{"type" => "session.status_idle", "stop_reason" => %{"type" => "end_turn"}}
      ])

    assert %ReqManagedAgents.TurnResult{terminal: :end_turn} = bedrock
    assert %ReqManagedAgents.TurnResult{terminal: :end_turn} = claude
  end
end
