defmodule ReqManagedAgents.Provisioner.Environment.Handle do
  @moduledoc "Handle to a provisioned, reusable environment image. new/1 absorbs the Store.File JSON (string-key) round-trip."
  @derive {Jason.Encoder, only: [:environment_id, :name, :digest]}
  @enforce_keys [:environment_id, :name, :digest]
  defstruct [:environment_id, :name, :digest, bootstrap: nil]

  @type t :: %__MODULE__{
          environment_id: String.t(),
          name: String.t(),
          digest: String.t(),
          bootstrap: %{script: String.t(), instructions: String.t()} | nil
        }

  @spec new(t() | map()) :: t()
  def new(%__MODULE__{} = h), do: h

  def new(%{environment_id: id, name: n, digest: d}),
    do: %__MODULE__{environment_id: id, name: n, digest: d}

  def new(%{"environment_id" => id, "name" => n, "digest" => d}),
    do: %__MODULE__{environment_id: id, name: n, digest: d}
end
