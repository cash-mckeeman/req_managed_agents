defmodule ReqManagedAgents.Providers.BedrockAgentCore.Recovery do
  @moduledoc "Decoded AgentCore inline frames do not establish native tool-result outcomes and ordered retry intervals."
  @behaviour ReqManagedAgents.Acceptance.Recovery
  alias ReqManagedAgents.Acceptance.RecoveryAttempt
  alias ReqManagedAgents.Evidence.Capture

  @impl true
  @spec attempts(Capture.t()) :: {:ok, [RecoveryAttempt.t()]} | {:error, :inconclusive}
  def attempts(%Capture{}), do: {:error, :inconclusive}
end
