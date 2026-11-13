defmodule ReqManagedAgents.OutcomeEvaluation do
  @moduledoc """
  One completed grader evaluation of an outcome.

  `result` is one of the five provider verdicts or `:unknown`; the provider's
  own end event is kept verbatim in `raw`, including grader usage; the usage in
  this end event is not added to `SessionResult.usage`. `new/1` validates
  every field and never coerces; an empty `start_event_id` is valid (an interrupted evaluation).
  """

  @keys [
    :outcome_id,
    :event_id,
    :start_event_id,
    :iteration,
    :result,
    :explanation,
    :processed_at,
    :raw
  ]
  @results [:satisfied, :needs_revision, :max_iterations_reached, :failed, :interrupted, :unknown]
  @optional_binaries [:event_id, :start_event_id, :explanation, :processed_at]

  @derive Jason.Encoder
  @enforce_keys [:outcome_id]
  defstruct [
    :outcome_id,
    :event_id,
    :start_event_id,
    :iteration,
    :explanation,
    :processed_at,
    result: :unknown,
    raw: %{}
  ]

  @type result ::
          :satisfied
          | :needs_revision
          | :max_iterations_reached
          | :failed
          | :interrupted
          | :unknown
  @typedoc "The provider's end event, verbatim; its keys and values are not interpreted here."
  @type raw :: map()
  @type t :: %__MODULE__{
          outcome_id: String.t(),
          event_id: String.t() | nil,
          start_event_id: String.t() | nil,
          iteration: non_neg_integer() | nil,
          result: result(),
          explanation: String.t() | nil,
          processed_at: String.t() | nil,
          raw: raw()
        }

  @doc "Validates a closed atom-keyed attribute map or an existing struct."
  @spec new(map() | t()) :: {:ok, t()} | {:error, {:invalid_outcome_evaluation, atom()}}
  def new(%__MODULE__{} = evaluation), do: new(Map.from_struct(evaluation))

  def new(%{} = attrs) do
    with :ok <- validate(attrs) do
      {:ok,
       %__MODULE__{
         outcome_id: attrs.outcome_id,
         event_id: Map.get(attrs, :event_id),
         start_event_id: Map.get(attrs, :start_event_id),
         iteration: Map.get(attrs, :iteration),
         result: Map.get(attrs, :result, :unknown),
         explanation: Map.get(attrs, :explanation),
         processed_at: Map.get(attrs, :processed_at),
         raw: Map.get(attrs, :raw, %{})
       }}
    end
  end

  def new(_other), do: invalid(:outcome_evaluation)

  defp validate(attrs) do
    cond do
      Map.keys(attrs) -- @keys != [] -> invalid(:keys)
      not nonempty_binary?(Map.get(attrs, :outcome_id)) -> invalid(:outcome_id)
      bad = Enum.find(@optional_binaries, &bad_optional_binary?(attrs, &1)) -> invalid(bad)
      not valid_iteration?(Map.get(attrs, :iteration)) -> invalid(:iteration)
      Map.get(attrs, :result, :unknown) not in @results -> invalid(:result)
      not plain_map?(Map.get(attrs, :raw, %{})) -> invalid(:raw)
      true -> :ok
    end
  end

  defp bad_optional_binary?(attrs, key) do
    value = Map.get(attrs, key)
    not (is_nil(value) or is_binary(value))
  end

  defp nonempty_binary?(value), do: is_binary(value) and value != ""
  defp valid_iteration?(value), do: is_nil(value) or (is_integer(value) and value >= 0)
  defp plain_map?(value), do: is_map(value) and not is_struct(value)
  defp invalid(reason), do: {:error, {:invalid_outcome_evaluation, reason}}
end
