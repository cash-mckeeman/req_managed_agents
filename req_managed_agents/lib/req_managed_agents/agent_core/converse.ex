defmodule ReqManagedAgents.AgentCore.Converse do
  @moduledoc "Compatibility entry point for `ReqManagedAgents.Providers.BedrockAgentCore.Converse`."
  @type tool_result :: ReqManagedAgents.Providers.BedrockAgentCore.Converse.tool_result()

  @spec inline_function(String.t(), String.t(), keyword()) :: map()
  defdelegate inline_function(name, description, schema),
    to: ReqManagedAgents.Providers.BedrockAgentCore.Converse

  @spec parse([map()]) :: %{
          stop_reason: String.t() | nil,
          tool_uses: [map()],
          text: String.t(),
          usage: map() | nil
        }
  defdelegate parse(events), to: ReqManagedAgents.Providers.BedrockAgentCore.Converse

  @spec resume_messages([map()], [tool_result()]) :: [map()]
  defdelegate resume_messages(uses, results),
    to: ReqManagedAgents.Providers.BedrockAgentCore.Converse
end
