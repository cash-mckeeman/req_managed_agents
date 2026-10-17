defmodule ReqManagedAgents.ModelConfig do
  @moduledoc """
  The canonical `:model_config` session option, with a closed set of atom keys.

  Every field is optional. `:model` carries a catalog model id or a provider-native
  value, `:api_key`, `:bearer_token_file` and `:base_url` supply the provider's
  credential and destination, and `:metadata` holds correlation information.

  `ReqManagedAgents.Session` validates the option before opening the provider and
  refuses fields the provider cannot apply. A binary `:model` is translated from
  a catalog id through `ReqManagedAgents.Provider.native_model/2`; non-binary
  models are treated as native values. Providers receive the map from `to_map/1`.

  This differs from `ReqManagedAgents.Agent.Spec`'s `model_config`, the
  provider-specific configuration interpreted by the selected provider at provisioning.
  """

  @keys [:model, :api_key, :bearer_token_file, :base_url, :metadata]
  @data_plane_keys [:api_key, :bearer_token_file, :base_url]

  @derive {Inspect, except: [:api_key]}
  defstruct [:model, :api_key, :bearer_token_file, :base_url, metadata: %{}]

  @typedoc "Open correlation metadata supplied by the caller."
  @type metadata :: map()

  @type t :: %__MODULE__{
          model: term(),
          api_key: String.t() | nil,
          bearer_token_file: String.t() | nil,
          base_url: String.t() | nil,
          metadata: metadata()
        }

  @type reason :: {:unknown_keys, [term()]} | {:invalid, atom()} | :not_a_map

  @doc """
  Coerces a struct, an atom-keyed map or a keyword list into a validated config.

  Unknown keys, including string keys, return `{:error, {:unknown_keys, keys}}`
  with sorted keys. Credentials and destinations must be binaries or `nil`;
  metadata must be a map or `nil`, which becomes an empty map. Invalid values
  return `{:error, {:invalid, key}}`. The model is passed through unchanged.
  Other inputs return `{:error, :not_a_map}`.
  """
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, reason()}
  def new(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> new()
  end

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      attrs
      |> Map.new()
      |> new()
    else
      {:error, :not_a_map}
    end
  end

  def new(%{} = attrs) do
    case Map.keys(attrs) -- @keys do
      [] -> validate(attrs)
      unknown -> {:error, {:unknown_keys, Enum.sort(unknown)}}
    end
  end

  def new(_other), do: {:error, :not_a_map}

  @doc "Renders the provider-facing atom-keyed map, omitting nil fields and empty metadata."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> Enum.reject(fn {key, value} -> is_nil(value) or (key == :metadata and value == %{}) end)
    |> Map.new()
  end

  @doc "Returns true when a credential or destination field is non-nil."
  @spec data_plane?(t()) :: boolean()
  def data_plane?(%__MODULE__{} = config),
    do: Enum.any?(@data_plane_keys, &(Map.fetch!(config, &1) != nil))

  defp validate(attrs) do
    attrs =
      Map.update(attrs, :metadata, %{}, fn
        nil -> %{}
        metadata -> metadata
      end)

    config = struct(__MODULE__, attrs)

    case Enum.find(@data_plane_keys, &(not optional_binary?(Map.fetch!(config, &1)))) do
      nil -> if is_map(config.metadata), do: {:ok, config}, else: {:error, {:invalid, :metadata}}
      key -> {:error, {:invalid, key}}
    end
  end

  defp optional_binary?(value), do: is_nil(value) or is_binary(value)
end
