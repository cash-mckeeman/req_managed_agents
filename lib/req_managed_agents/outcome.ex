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

  @doc """
  Coerce a map or an existing `%Outcome{}` into a validated `%Outcome{}`.

  The single shape gate for the `:outcome` option: `description` and `rubric`
  must be binaries under atom keys; `max_iterations` is optional. Anything else
  returns `{:error, :invalid_outcome}`.
  """
  @spec new(t() | map()) :: {:ok, t()} | {:error, :invalid_outcome}
  def new(%__MODULE__{description: d, rubric: r} = outcome) when is_binary(d) and is_binary(r),
    do: {:ok, outcome}

  def new(%{description: d, rubric: r} = map) when is_binary(d) and is_binary(r),
    do:
      {:ok, %__MODULE__{description: d, rubric: r, max_iterations: Map.get(map, :max_iterations)}}

  def new(_other), do: {:error, :invalid_outcome}
end
