defmodule ReqManagedAgents.Providers.BedrockAgentCore.HarnessSpec do
  @moduledoc "Typed CreateHarness spec assembled by `BedrockAgentCore.build_spec/2`. `environment` is the opaque, provider-verbatim `Environment.Spec.config` passthrough (env vars live nested inside it, as the AWS API shapes them — there is no separate indexed field)."
  @derive Jason.Encoder
  @enforce_keys [:name, :execution_role_arn, :system_prompt, :model]
  defstruct [
    :name,
    :execution_role_arn,
    :system_prompt,
    :model,
    tools: [],
    environment: nil
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          execution_role_arn: String.t(),
          system_prompt: String.t(),
          model: String.t() | map() | nil,
          tools: [map()],
          environment: map() | nil
        }
end
