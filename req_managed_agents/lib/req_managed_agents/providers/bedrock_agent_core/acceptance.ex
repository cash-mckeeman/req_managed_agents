defmodule ReqManagedAgents.Providers.BedrockAgentCore.Acceptance do
  @moduledoc "Basic AgentCore acceptance through the normal Session and evidence pipeline."
  @behaviour ReqManagedAgents.Acceptance.Scenario
  alias ReqManagedAgents.Acceptance.{Basic, Config, Context, Proposal}
  alias ReqManagedAgents.{ModelConfig, Providers.BedrockAgentCore}
  alias ReqManagedAgents.Providers.BedrockAgentCore.Client

  @impl true
  def propose(%Config{scenario: :basic, provider: :agentcore} = config) do
    with :ok <- validate(config), do: Proposal.new(config)
  end

  def propose(_), do: {:error, :unsupported_scenario}

  @doc false
  @spec validate(Config.t()) :: :ok | {:error, :invalid_provider_config}
  def validate(config) do
    resource = config.resource
    inputs = config.inputs

    valid =
      valid_resource?(resource) and valid_inputs?(inputs, config.bounds.timeout_ms) and
        config.bounds.calls == 1

    if valid, do: :ok, else: {:error, :invalid_provider_config}
  end

  defp valid_resource?(resource) do
    Enum.sort(Map.keys(resource)) == ~w(reference region runtime_session_id) and
      resource["region"] == "us-east-1" and is_binary(resource["reference"]) and
      Regex.match?(
        ~r/\Aarn:aws:bedrock-agentcore:us-east-1:[0-9]{12}:harness\/[a-zA-Z0-9_-]+\z/,
        resource["reference"]
      ) and
      is_binary(resource["runtime_session_id"]) and
      Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{32,99}\z/, resource["runtime_session_id"])
  end

  defp valid_inputs?(inputs, timeout) do
    Enum.sort(Map.keys(inputs)) == ~w(max_tokens model prompt timeout_seconds) and
      is_binary(inputs["prompt"]) and String.trim(inputs["prompt"]) != "" and
      valid_model?(inputs["model"]) and positive?(inputs["max_tokens"]) and
      positive?(inputs["timeout_seconds"]) and inputs["timeout_seconds"] * 1000 <= timeout
  end

  defp valid_model?(nil), do: true
  defp valid_model?("bedrock:" <> id), do: id != ""
  defp valid_model?(_), do: false
  defp positive?(value), do: is_integer(value) and value > 0

  @impl true
  def run(%Context{} = context) do
    config = context.config
    {:ok, model} = ModelConfig.new(model: config.inputs["model"])
    transport = transport(context.transport, config.bounds.timeout_ms)

    opts = [
      harness_arn: config.resource["reference"],
      runtime_session_id: config.resource["runtime_session_id"],
      prompt: config.inputs["prompt"],
      model_config: model,
      invoke_retries: 0,
      idle_timeout: config.bounds.timeout_ms,
      timeout_seconds: config.inputs["timeout_seconds"],
      max_iterations: 1,
      max_tokens: config.inputs["max_tokens"]
    ]

    Basic.session(context, BedrockAgentCore, Keyword.merge(opts, transport))
  end

  defp transport(opts, timeout) do
    case {opts[:client], opts[:invoke_fun]} do
      {%Client{} = client, nil} ->
        [
          client: %{
            client
            | req_options: Keyword.put(client.req_options, :retry, false),
              receive_timeout: timeout
          }
        ]

      {nil, fun} when is_function(fun, 1) ->
        [invoke_fun: fun]

      {nil, nil} ->
        [client: Client.new(req_options: [retry: false], receive_timeout: timeout)]
    end
  end

  @impl true
  def assess(context, observations), do: Basic.assess(context, observations, :agentcore)
end
