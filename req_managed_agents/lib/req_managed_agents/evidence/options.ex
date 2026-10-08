defmodule ReqManagedAgents.Evidence.Options do
  @moduledoc "Aggregate capture bounds and the private content retention policy."
  alias ReqManagedAgents.Evidence.{Error, Validation}

  defstruct max_pages: 100,
            max_records: 10_000,
            max_bytes: 10_485_760,
            timeout_ms: 30_000,
            content: :drop

  @type t :: %__MODULE__{
          max_pages: pos_integer(),
          max_records: pos_integer(),
          max_bytes: pos_integer(),
          timeout_ms: pos_integer(),
          content: :drop | :retain
        }
  @contents %{"drop" => :drop, "retain" => :retain}

  @doc "Validates positive bounds and rejects unknown options. Content defaults to drop."
  @spec new(keyword() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = attrs), do: validate(Map.from_struct(attrs))

  def new(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
       do: validate(Map.new(opts)),
       else: Error.error(:invalid_options)
  end

  def new(_), do: Error.error(:invalid_options)

  defp validate(attrs) do
    defaults = Map.from_struct(%__MODULE__{})

    specs =
      Enum.map(defaults, fn
        {:content, default} -> {:content, &Validation.enum(&1, @contents), default}
        {key, default} -> {key, &Validation.positive/1, default}
      end)

    with true <- Validation.only_keys?(attrs, Map.keys(defaults)),
         {:ok, fields} <- Validation.fields(attrs, specs) do
      {:ok, struct!(__MODULE__, fields)}
    else
      _ -> Error.error(:invalid_options)
    end
  end
end
