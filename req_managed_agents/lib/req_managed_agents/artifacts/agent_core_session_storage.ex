defmodule ReqManagedAgents.Artifacts.AgentCoreSessionStorage do
  @moduledoc "Compatibility artifact store for Bedrock AgentCore session storage."
  @behaviour ReqManagedAgents.Artifacts
  alias ReqManagedAgents.Providers.BedrockAgentCore.Artifacts

  defdelegate store(client, arn, sid, base, opts \\ []), to: Artifacts

  @impl true
  def list(store, opts \\ []), do: legacy_result(Artifacts.list(store, opts))

  @impl true
  def fetch(store, name, opts \\ []), do: legacy_result(Artifacts.fetch(store, name, opts))

  @impl true
  def put(store, name, contents, opts \\ []),
    do: legacy_result(Artifacts.put(store, name, contents, opts))

  @impl true
  def delete(store, name, opts \\ []), do: legacy_result(Artifacts.delete(store, name, opts))

  defp legacy_result(
         {:error,
          {:command_failed, %ReqManagedAgents.Providers.BedrockAgentCore.CommandResult{} = result}}
       ),
       do:
         {:error,
          {:command_failed,
           struct!(ReqManagedAgents.AgentCore.CommandResult, Map.from_struct(result))}}

  defp legacy_result(result), do: result
end
