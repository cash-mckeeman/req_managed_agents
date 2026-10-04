defmodule ReqManagedAgents.OpenTelemetry.SemConv do
  @moduledoc "OTel GenAI semantic-convention lookups for the managed-agents (Anthropic) path."

  @spec provider_name() :: String.t()
  def provider_name, do: "anthropic"

  @spec finish_reason(atom()) :: String.t()
  def finish_reason(:end_turn), do: "end_turn"
  def finish_reason(:terminated), do: "terminated"
  def finish_reason(:error), do: "error"
  def finish_reason(:retries_exhausted), do: "retries_exhausted"
  def finish_reason(_), do: "terminated"
end
