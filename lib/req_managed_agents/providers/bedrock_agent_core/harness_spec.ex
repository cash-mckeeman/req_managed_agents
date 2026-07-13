defmodule ReqManagedAgents.Providers.BedrockAgentCore.HarnessSpec do
  @moduledoc "Typed CreateHarness spec assembled by `BedrockAgentCore.build_spec/2`. `environment`/`environment_variables` are opaque provider-verbatim passthrough."
  @derive Jason.Encoder
  @enforce_keys [:name, :execution_role_arn, :system_prompt, :model]
  defstruct [
    :name,
    :execution_role_arn,
    :system_prompt,
    :model,
    tools: [],
    environment: nil,
    environment_variables: nil
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          execution_role_arn: String.t(),
          system_prompt: String.t(),
          model: term(),
          tools: [map()],
          environment: map() | nil,
          environment_variables: map() | nil
        }
end
