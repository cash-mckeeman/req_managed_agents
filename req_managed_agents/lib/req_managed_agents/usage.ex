defmodule ReqManagedAgents.Usage do
  @moduledoc """
  Observed token counts and their measurement coverage.

  Input counts retain their provider's meaning, recorded in `input_token_basis`.
  Missing cache measurements are `nil`; measured zero remains zero. When
  `complete?` is false, numeric counts are observed subtotals. Completeness
  covers represented contributions, not additional unfinished provider work.
  """

  @keys [
    :input_tokens,
    :output_tokens,
    :cache_read_input_tokens,
    :cache_creation_input_tokens,
    :input_token_basis,
    :complete?,
    :raw
  ]
  @count_keys [
    :input_tokens,
    :output_tokens,
    :cache_read_input_tokens,
    :cache_creation_input_tokens
  ]
  @bases [:uncached, :inclusive, :unknown, :none]

  @derive Jason.Encoder
  defstruct input_tokens: 0,
            output_tokens: 0,
            cache_read_input_tokens: nil,
            cache_creation_input_tokens: nil,
            input_token_basis: :unknown,
            complete?: false,
            raw: []

  @type input_token_basis :: :uncached | :inclusive | :unknown | :none
  @typedoc "Provider-verbatim usage objects; their keys and values are not interpreted here."
  @type raw :: [map()]
  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_input_tokens: non_neg_integer() | nil,
          cache_creation_input_tokens: non_neg_integer() | nil,
          input_token_basis: input_token_basis(),
          complete?: boolean(),
          raw: raw()
        }

  @doc """
  Validates a closed atom-keyed projection or an existing usage struct.

  Missing or nil input/output becomes zero with incomplete coverage; other
  invalid input/output returns a tagged error. Invalid optional cache counts
  become nil. An explicit false coverage flag cannot be upgraded.
  """
  @spec new(map() | t()) :: {:ok, t()} | {:error, {:invalid_usage, atom()}}
  def new(%__MODULE__{} = usage), do: usage |> Map.from_struct() |> new()

  def new(%{} = attrs) do
    with :ok <- validate(attrs) do
      usage = %__MODULE__{
        input_tokens: Map.get(attrs, :input_tokens) || 0,
        output_tokens: Map.get(attrs, :output_tokens) || 0,
        cache_read_input_tokens: count(Map.get(attrs, :cache_read_input_tokens)),
        cache_creation_input_tokens: count(Map.get(attrs, :cache_creation_input_tokens)),
        input_token_basis: Map.get(attrs, :input_token_basis, :unknown),
        complete?: Map.get(attrs, :complete?, true) and observed?(attrs),
        raw: Map.get(attrs, :raw, [])
      }

      if valid_empty?(usage), do: {:ok, usage}, else: invalid(:input_token_basis)
    end
  end

  def new(_other), do: invalid(:usage)

  @doc "The known empty accumulation identity, distinct from an absent usage report."
  @spec zero() :: t()
  def zero do
    %__MODULE__{
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0,
      input_token_basis: :none,
      complete?: true
    }
  end

  @doc "Adds contributions once; missing measurements make their total incomplete."
  @spec add(t(), t() | nil) :: t()
  def add(%__MODULE__{} = acc, nil) do
    %{
      acc
      | cache_read_input_tokens: nil,
        cache_creation_input_tokens: nil,
        input_token_basis: :unknown,
        complete?: false
    }
  end

  def add(%__MODULE__{} = acc, %__MODULE__{} = usage) do
    basis = merge_basis(acc.input_token_basis, usage.input_token_basis)

    %__MODULE__{
      input_tokens: acc.input_tokens + usage.input_tokens,
      output_tokens: acc.output_tokens + usage.output_tokens,
      cache_read_input_tokens:
        add_count(acc.cache_read_input_tokens, usage.cache_read_input_tokens),
      cache_creation_input_tokens:
        add_count(acc.cache_creation_input_tokens, usage.cache_creation_input_tokens),
      input_token_basis: basis,
      complete?: acc.complete? and usage.complete? and basis != :unknown,
      raw: acc.raw ++ usage.raw
    }
  end

  defp validate(attrs) do
    cond do
      Map.keys(attrs) -- @keys != [] -> invalid(:keys)
      not optional_count?(Map.get(attrs, :input_tokens)) -> invalid(:input_tokens)
      not optional_count?(Map.get(attrs, :output_tokens)) -> invalid(:output_tokens)
      Map.get(attrs, :input_token_basis, :unknown) not in @bases -> invalid(:input_token_basis)
      not is_boolean(Map.get(attrs, :complete?, true)) -> invalid(:complete?)
      not valid_raw?(Map.get(attrs, :raw, [])) -> invalid(:raw)
      true -> :ok
    end
  end

  defp observed?(attrs),
    do:
      Enum.all?(@count_keys, &(count(Map.get(attrs, &1)) != nil)) and
        Map.get(attrs, :input_token_basis, :unknown) != :unknown

  defp valid_empty?(%__MODULE__{input_token_basis: :none} = usage),
    do: Enum.all?(@count_keys, &(Map.fetch!(usage, &1) == 0)) and usage.raw == []

  defp valid_empty?(_usage), do: true
  defp valid_raw?(raw), do: is_list(raw) and Enum.all?(raw, &(is_map(&1) and not is_struct(&1)))
  defp optional_count?(value), do: is_nil(value) or count(value) != nil
  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: nil
  defp invalid(key), do: {:error, {:invalid_usage, key}}
  defp add_count(nil, _right), do: nil
  defp add_count(_left, nil), do: nil
  defp add_count(left, right), do: left + right
  defp merge_basis(:none, right), do: right
  defp merge_basis(left, :none), do: left
  defp merge_basis(basis, basis), do: basis
  defp merge_basis(_left, _right), do: :unknown
end
