defmodule ReqManagedAgents.Providers.BedrockAgentCore.HarnessStatus do
  @moduledoc """
  The AgentCore harness status vocabulary, as one total classification.

  This replaces two lists that disagreed about `DELETING` — it was
  terminal-for-reuse in one and absent from the other, so a harness that began
  deleting while the ready-wait was polling it fell into the keep-polling branch
  and could never resolve.

  An unrecognized status terminates rather than polling: burning a full budget
  and then reporting a ready-timeout misdescribes what happened, and a hard error
  on a new status is the signal to update this module.
  """

  @type t :: :ready | :creating | :terminating | {:failed, String.t()} | {:unknown, String.t()}

  @doc """
  Classifies a harness status string. Total over `String.t()` — there is no
  catch-all "keep polling" bucket.
  """
  @spec classify(String.t()) :: t()
  def classify("READY"), do: :ready
  def classify(s) when s in ~w(CREATING UPDATING), do: :creating
  def classify("DELETING"), do: :terminating
  def classify(s) when s in ~w(CREATE_FAILED UPDATE_FAILED DELETE_FAILED), do: {:failed, s}
  def classify(s) when is_binary(s), do: {:unknown, s}
end
