defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.RecoveryExpectation do
  @moduledoc "A selected builtin tool and exact decoded native arguments for recovery acceptance."
  alias ReqManagedAgents.Evidence.Validation
  @enforce_keys [:family, :target, :arguments]
  @derive {Inspect, except: [:target, :arguments]}
  defstruct @enforce_keys

  @typedoc "Arguments remain provider-verbatim JSON at the private scenario edge."
  @type t :: %__MODULE__{
          family: :builtin,
          target: String.t(),
          arguments: %{String.t() => Jason.Encoder.t()}
        }

  @doc "Reject non-builtin expectations and absent, non-JSON or ambiguous fields."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_provider_config}
  def new(%{"family" => "builtin", "target" => target, "arguments" => arguments} = raw) do
    with true <- map_size(raw) == 3,
         {:ok, target} <- Validation.id(target),
         true <- is_map(arguments) and Validation.json?(arguments) do
      {:ok, %__MODULE__{family: :builtin, target: target, arguments: arguments}}
    else
      _ -> {:error, :invalid_provider_config}
    end
  end

  def new(_), do: {:error, :invalid_provider_config}
end
