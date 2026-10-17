defmodule ReqManagedAgents.Acceptance do
  @moduledoc "On-demand managed-provider acceptance proposals."
  alias ReqManagedAgents.Acceptance.{Config, Proposal}
  @doc "Propose an acceptance run without provider activity."
  @spec propose(Config.t()) :: {:ok, Proposal.t()} | {:error, Config.error()}
  def propose(%Config{} = config), do: Proposal.new(config)
end
