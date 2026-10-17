defmodule ReqManagedAgents.Acceptance.Bounds do
  @moduledoc "Positive, explicit ceilings for one acceptance run."
  @enforce_keys [:calls, :records, :bytes, :timeout_ms]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          calls: pos_integer(),
          records: pos_integer(),
          bytes: pos_integer(),
          timeout_ms: pos_integer()
        }

  @doc "Validate a closed JSON limits object."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_bounds}
  def new(values) when is_map(values) do
    if Enum.sort(Map.keys(values)) == ~w(bytes calls records timeout_ms) and
         Enum.all?(values, fn {_key, value} -> is_integer(value) and value > 0 end) do
      {:ok,
       %__MODULE__{
         calls: values["calls"],
         records: values["records"],
         bytes: values["bytes"],
         timeout_ms: values["timeout_ms"]
       }}
    else
      {:error, :invalid_bounds}
    end
  end

  def new(_), do: {:error, :invalid_bounds}

  @doc "Render the limits as JSON fields."
  @spec to_wire(t()) :: %{String.t() => pos_integer()}
  def to_wire(%__MODULE__{} = bounds) do
    %{
      "calls" => bounds.calls,
      "records" => bounds.records,
      "bytes" => bounds.bytes,
      "timeout_ms" => bounds.timeout_ms
    }
  end
end
