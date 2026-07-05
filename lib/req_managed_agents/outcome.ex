defmodule ReqManagedAgents.Outcome do
  @moduledoc """
  A graded-session goal: a natural-language `description` of what to achieve and
  a `rubric` the provider grades the result against, optionally bounded by
  `max_iterations` revise cycles.

  Pass it as the `:outcome` option to `ReqManagedAgents.Session.run/2` (or
  `start_link/2`) to kick off a `user.define_outcome` graded session instead of a
  plain `:prompt`. A map with the same atom keys is accepted interchangeably.
  """
  @enforce_keys [:description, :rubric]
  defstruct [:description, :rubric, :max_iterations]

  @type t :: %__MODULE__{
          description: String.t(),
          rubric: String.t(),
          max_iterations: pos_integer() | nil
        }
end
