defmodule ReqManagedAgents.AgentCore.SigV4 do
  @moduledoc "Compatibility AWS signer with the AgentCore dependency preflight and default service."
  alias ReqManagedAgents.AWS.SigV4
  alias ReqManagedAgents.Providers.BedrockAgentCore.Deps
  @type creds :: SigV4.creds()

  @spec sign_request(atom(), String.t(), iodata(), keyword()) :: [{String.t(), String.t()}]
  def sign_request(method, url, body, opts \\ []) do
    Deps.ensure!()

    SigV4.sign_request(
      method,
      url,
      body,
      Keyword.put(opts, :service, opts[:service] || "bedrock-agentcore")
    )
  end

  @spec from_env(keyword()) :: creds()
  defdelegate from_env(opts \\ []), to: SigV4
end
