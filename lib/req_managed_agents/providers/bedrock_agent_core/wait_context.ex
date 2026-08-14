defmodule ReqManagedAgents.Providers.BedrockAgentCore.WaitContext do
  @moduledoc """
  What a provisioning wait observed when it gave up.

  Wait errors previously carried bare atoms, so a timeout could not be tied to a
  harness, a last-seen status, or an elapsed time — the reason a real canary
  failure could not be diagnosed from its run log.

  `harness_id` names the resource the wait was tracking: its `harnessId` during
  the `:ready` and `:endpoint` phases, and its *name* during the `:deleted` phase,
  because that wait polls `ListHarnesses` by name and the id of a harness that is
  going away is not what identifies it to the next create.

  `:endpoint` is the wait for the harness endpoint an invoke will reach. It
  carries the harness id rather than the endpoint name because the endpoint is
  chosen by the caller (`:endpoint_name`, defaulting to the one the data plane
  defaults to) and the harness is what a reader has to go and look at.
  """

  @enforce_keys [:harness_id, :phase]
  defstruct [:harness_id, :phase, :last_status, :elapsed_ms, :polls]

  @type phase :: :ready | :endpoint | :deleted
  @type t :: %__MODULE__{
          harness_id: String.t(),
          phase: phase(),
          last_status: String.t() | nil,
          elapsed_ms: non_neg_integer() | nil,
          polls: non_neg_integer() | nil
        }
end
