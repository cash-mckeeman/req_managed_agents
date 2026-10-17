defmodule ReqManagedAgents.Acceptance.Consumption do
  @moduledoc "Observed artifact consumption; unknown invocation counts remain null."
  alias ReqManagedAgents.Evidence.Capture
  @enforce_keys [:invocations, :history_pages, :records, :bytes]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          invocations: non_neg_integer() | nil,
          history_pages: non_neg_integer() | nil,
          records: non_neg_integer(),
          bytes: non_neg_integer()
        }

  @doc "Count native evidence, without treating local attempts as successful remote invocations."
  @spec new(Capture.t() | nil, non_neg_integer()) :: {:ok, t()}
  def new(nil, bytes),
    do: {:ok, %__MODULE__{invocations: nil, history_pages: nil, records: 0, bytes: bytes}}

  def new(capture, bytes) do
    invocations = if Enum.any?(capture.records, &(&1.kind == :native)), do: 1, else: nil

    {:ok,
     %__MODULE__{
       invocations: invocations,
       history_pages: Enum.sum(Enum.map(capture.sources, & &1.pages)),
       records: length(capture.records),
       bytes: bytes
     }}
  end

  @doc "Render known quantities; null explicitly denotes an unknown count."
  @spec to_wire(t()) :: %{String.t() => Jason.Encoder.t()}
  def to_wire(consumption),
    do: Map.from_struct(consumption) |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
end
