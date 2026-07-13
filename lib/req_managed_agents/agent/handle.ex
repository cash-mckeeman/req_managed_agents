defmodule ReqManagedAgents.Agent.Handle do
  @moduledoc "Handle to a provisioned, reusable agent. new/1 absorbs the Store.File JSON (string-key) round-trip."
  @derive Jason.Encoder
  @enforce_keys [:agent_id, :name, :digest]
  defstruct [:agent_id, :name, :digest]
  @type t :: %__MODULE__{agent_id: String.t(), name: String.t(), digest: String.t()}

  @spec new(t() | map()) :: t()
  def new(%__MODULE__{} = h), do: h
  def new(%{agent_id: id, name: n, digest: d}), do: %__MODULE__{agent_id: id, name: n, digest: d}

  def new(%{"agent_id" => id, "name" => n, "digest" => d}),
    do: %__MODULE__{agent_id: id, name: n, digest: d}
end
