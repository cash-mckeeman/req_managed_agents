defmodule ReqManagedAgents.AgentCore do
  @moduledoc """
  Bedrock AgentCore entry point.

  The per-turn invoke/resume loop now lives in the unified `ReqManagedAgents.Session` driving
  the `ReqManagedAgents.Providers.BedrockAgentCore` provider (`:request_response` mode); this is
  a thin compatibility shim. The SigV4-signed control-plane / data-plane wire client is
  `ReqManagedAgents.AgentCore.Client`.
  """

  @doc """
  Drive a Bedrock AgentCore Harness to completion via the unified Session. Returns
  `{:ok, %{terminal, stop_reason, events}}` on a clean exit, or `{:error, reason}` on timeout,
  a surfaced `{:harness_stream_error, _, _}`, `:early_termination`, or a client error.

  Required opts: `:harness_arn`, `:runtime_session_id`, `:handler`. Optional: `:model`,
  `:prompt`, `:context`, `:timeout`, `:max_turns`, `:telemetry_metadata` (and `:client` /
  `:invoke_fun` for tests).
  """
  @spec invoke_to_completion(keyword()) :: {:ok, map()} | {:error, term()}
  def invoke_to_completion(opts) do
    ReqManagedAgents.Session.run(ReqManagedAgents.Providers.BedrockAgentCore, opts)
  end
end
