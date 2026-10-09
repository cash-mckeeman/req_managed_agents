defmodule ReqManagedAgents.AgentCore.EventStream do
  @moduledoc "Compatibility entry point for `ReqManagedAgents.Providers.BedrockAgentCore.EventStream`."
  @spec decode(binary()) :: {[map()], binary()}
  defdelegate decode(buffer), to: ReqManagedAgents.Providers.BedrockAgentCore.EventStream
end
