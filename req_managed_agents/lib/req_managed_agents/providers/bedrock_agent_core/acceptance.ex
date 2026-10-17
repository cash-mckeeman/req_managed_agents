defmodule ReqManagedAgents.Providers.BedrockAgentCore.Acceptance do
  @moduledoc "One-turn acceptance of an explicitly selected AgentCore harness."
  @behaviour ReqManagedAgents.Acceptance.Scenario
  alias ReqManagedAgents.Acceptance.{Basic, Config, Context, Proposal}
  alias ReqManagedAgents.ModelConfig
  alias ReqManagedAgents.Providers.BedrockAgentCore
  alias ReqManagedAgents.Providers.BedrockAgentCore.Client

  @impl true
  def propose(%Config{provider: :agentcore, scenario: :basic} = config) do
    with :ok <- validate(config), do: Proposal.new(config)
  end

  def propose(_), do: {:error, :unsupported_scenario}

  @doc false
  @spec validate(Config.t()) :: :ok | {:error, :invalid_provider_config}
  def validate(config) do
    if resource?(config.resource) and inputs?(config.inputs, config.bounds.timeout_ms) and
         config.bounds.calls == 1, do: :ok, else: {:error, :invalid_provider_config}
  end

  defp resource?(
         %{"reference" => arn, "region" => "us-east-1", "runtime_session_id" => sid} = resource
       )
       when is_binary(arn) and is_binary(sid) do
    map_size(resource) == 3 and
      Regex.match?(
        ~r/\Aarn:aws:bedrock-agentcore:us-east-1:[0-9]{12}:harness\/[a-zA-Z0-9_-]+\z/,
        arn
      ) and
      Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{32,99}\z/, sid)
  end

  defp resource?(_), do: false

  defp inputs?(
         %{
           "prompt" => prompt,
           "model" => model,
           "max_tokens" => tokens,
           "timeout_seconds" => seconds
         } = inputs,
         timeout
       )
       when is_binary(prompt) and is_integer(tokens) and tokens > 0 and is_integer(seconds) and
              seconds > 0 do
    map_size(inputs) == 4 and String.trim(prompt) != "" and model?(model) and
      seconds * 1000 <= timeout
  end

  defp inputs?(_, _), do: false
  defp model?(nil), do: true
  defp model?("bedrock:" <> id), do: id != ""
  defp model?(_), do: false

  @impl true
  def run(%Context{} = context) do
    config = context.config
    {:ok, model} = ModelConfig.new(model: config.inputs["model"])

    native = [
      harness_arn: config.resource["reference"],
      runtime_session_id: config.resource["runtime_session_id"],
      model_config: model,
      prompt: config.inputs["prompt"],
      invoke_retries: 0,
      max_iterations: 1,
      max_tokens: config.inputs["max_tokens"],
      timeout_seconds: config.inputs["timeout_seconds"],
      idle_timeout: config.bounds.timeout_ms
    ]

    Basic.session(context, BedrockAgentCore, native ++ transport(context))
  end

  defp transport(%Context{transport: opts, config: config}) do
    case {opts[:client], opts[:invoke_fun]} do
      {%Client{} = client, nil} ->
        [
          client: %{
            client
            | req_options: Keyword.put(client.req_options, :retry, false),
              receive_timeout: config.bounds.timeout_ms
          }
        ]

      {nil, fun} when is_function(fun, 1) ->
        [invoke_fun: fun]

      {nil, nil} ->
        [
          client:
            Client.new(req_options: [retry: false], receive_timeout: config.bounds.timeout_ms)
        ]
    end
  end

  @impl true
  def assess(context, observations), do: Basic.assess(context, observations, :agentcore)
end
