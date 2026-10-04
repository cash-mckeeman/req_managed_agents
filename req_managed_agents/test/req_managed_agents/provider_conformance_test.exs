defmodule ReqManagedAgents.ProviderConformanceTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Providers.{BedrockAgentCore, ClaudeManagedAgents, Local}

  # Every provider implements the shared callbacks; each mode adds its own.
  @shared [
    {:mode, 0},
    {:open, 2},
    {:kickoff_input, 1},
    {:user_input, 1},
    {:resume_input, 2},
    {:normalize, 1},
    {:provision, 2},
    {:session_id, 1},
    {:ref, 1},
    {:consumer, 1},
    {:resumed?, 1}
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

    for {f, a} <-
          @shared ++
            [{:push_input, 2}, {:turn_boundary?, 1}, {:reconnect, 3}, {:pending_tool_uses, 1}] do
      assert function_exported?(ClaudeManagedAgents, f, a),
             "ClaudeManagedAgents missing #{f}/#{a}"
    end

    assert function_exported?(ClaudeManagedAgents, :teardown, 2),
           "ClaudeManagedAgents missing teardown/2"
  end

  test "Local is a complete :request_response provider" do
    Code.ensure_loaded!(Local)
    assert Local.mode() == :request_response

    for {f, a} <- @shared ++ [{:poll_turn, 2}] do
      assert function_exported?(Local, f, a), "Local missing #{f}/#{a}"
    end

    assert function_exported?(Local, :teardown, 2), "Local missing teardown/2"
    assert function_exported?(Local, :text_delta, 1), "Local missing text_delta/1"
  end

  test "conn accessors answer for each provider's own conn shape" do
    ref = make_ref()
    consumer = self()

    bedrock_conn = %{harness_arn: "arn", sid: "sid-1", session_id: "sid-1"}
    assert BedrockAgentCore.session_id(bedrock_conn) == "sid-1"
    assert BedrockAgentCore.ref(bedrock_conn) == nil
    assert BedrockAgentCore.consumer(bedrock_conn) == nil
    refute BedrockAgentCore.resumed?(bedrock_conn)

    fresh_claude_conn = %{client: :c, session_id: "sess-1", ref: ref, consumer: consumer}
    assert ClaudeManagedAgents.session_id(fresh_claude_conn) == "sess-1"
    assert ClaudeManagedAgents.ref(fresh_claude_conn) == ref
    assert ClaudeManagedAgents.consumer(fresh_claude_conn) == consumer
    refute ClaudeManagedAgents.resumed?(fresh_claude_conn)

    resumed_claude_conn = %{client: :c, session_id: "sess-2", ref: nil, resume: true}
    assert ClaudeManagedAgents.session_id(resumed_claude_conn) == "sess-2"
    assert ClaudeManagedAgents.ref(resumed_claude_conn) == nil
    assert ClaudeManagedAgents.consumer(resumed_claude_conn) == nil
    assert ClaudeManagedAgents.resumed?(resumed_claude_conn)

    local_conn = %Local{session_id: "local-1"}
    assert Local.session_id(local_conn) == "local-1"
    assert Local.ref(local_conn) == nil
    assert Local.consumer(local_conn) == nil
    refute Local.resumed?(local_conn)
  end

  test "all providers normalize to a %TurnResult{}" do
    bedrock = BedrockAgentCore.normalize([%{"messageStop" => %{"stopReason" => "end_turn"}}])

    claude =
      ClaudeManagedAgents.normalize([
        %{"type" => "session.status_idle", "stop_reason" => %{"type" => "end_turn"}}
      ])

    local =
      Local.normalize([
        %{
          "type" => "local.model_response",
          "message" => %{"role" => "assistant", "content" => "hi"},
          "finish_reason" => "stop",
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
        }
      ])

    assert %ReqManagedAgents.TurnResult{terminal: :end_turn} = bedrock
    assert %ReqManagedAgents.TurnResult{terminal: :end_turn} = claude
    assert %ReqManagedAgents.TurnResult{terminal: :end_turn} = local
  end
end
