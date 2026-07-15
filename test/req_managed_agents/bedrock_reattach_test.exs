defmodule ReqManagedAgents.BedrockReattachTest do
  @moduledoc """
  Issue #80: `session_id:` (RMA-canonical) targets an EXISTING AgentCore runtime
  session and reports resumed? true, engaging the #66 reattach seam. Fresh opens
  (caller-minted :runtime_session_id, no :session_id) are unchanged and stay
  resumed? false. Within-window only — beyond-window re-seed is 0.11.
  """
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Providers.BedrockAgentCore

  @arn "arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/test-harness"

  # invoke_fun injection keeps open/2 from building a real AWS client. A module
  # attribute can't hold an anonymous function (not an escapable literal), so
  # this is a named function passed via capture.
  defp noop_invoke(_inv), do: {:error, :not_called_in_this_test}

  test "session_id: reattaches — becomes the runtime session id, resumed? true" do
    {:ok, conn} =
      BedrockAgentCore.open(
        [session_id: "rs-existing", harness_arn: @arn, invoke_fun: &noop_invoke/1],
        self()
      )

    assert BedrockAgentCore.session_id(conn) == "rs-existing"
    assert BedrockAgentCore.resumed?(conn)
  end

  test "fresh open is unchanged: runtime_session_id required, resumed? false" do
    {:ok, conn} =
      BedrockAgentCore.open(
        [runtime_session_id: "rs-fresh", harness_arn: @arn, invoke_fun: &noop_invoke/1],
        self()
      )

    assert BedrockAgentCore.session_id(conn) == "rs-fresh"
    refute BedrockAgentCore.resumed?(conn)
  end

  test "fresh open without runtime_session_id still raises (contract unchanged)" do
    assert_raise KeyError, fn ->
      BedrockAgentCore.open([harness_arn: @arn, invoke_fun: &noop_invoke/1], self())
    end
  end
end
