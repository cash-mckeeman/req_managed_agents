defmodule ReqManagedAgents.Acceptance.Scenario do
  @moduledoc "The provider-specific acceptance seam; native provider clients remain unchanged."
  alias ReqManagedAgents.Acceptance.{Assertion, Config, Context, Observation, Proposal}
  @callback propose(Config.t()) :: {:ok, Proposal.t()} | {:error, atom()}
  @callback run(Context.t()) :: {:ok, [Observation.t()]} | {:error, atom(), [Observation.t()]}
  @callback assess(Context.t(), [Observation.t()]) :: [Assertion.t()]
end
