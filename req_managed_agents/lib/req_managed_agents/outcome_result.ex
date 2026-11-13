defmodule ReqManagedAgents.OutcomeResult do
  @moduledoc """
  What a session's accepted events show for one outcome.

  `evaluations` holds only completed `OutcomeEvaluation` values for this
  outcome. `new/1` is the only place that derives `status` and the order of
  `evaluations`, and it recomputes both for an existing struct, so neither is
  accepted as input. Evaluations are ordered by iteration (nil iterations
  last, input order for ties). `status` is `:unknown` when an iteration is nil or
  shared or `issues` holds a poisoning issue (see `poisoning_issues/0`);
  otherwise `:pending` with no evaluations; otherwise the verdict at the
  greatest iteration. `:pending` is not an active-evaluation state.
  """

  alias ReqManagedAgents.OutcomeEvaluation

  @keys [:outcome_id, :description, :definition, :evaluations, :issues]
  @issues [
    :unknown_result,
    :missing_event_id,
    :invalid_iteration,
    :invalid_description,
    :invalid_explanation,
    :invalid_processed_at,
    :invalid_start_event_id,
    :invalid_evaluation,
    :invalid_outcome,
    :conflicting_event_id,
    :conflicting_evaluation,
    :conflicting_definition
  ]
  @poisoning_issues [
    :invalid_iteration,
    :invalid_evaluation,
    :invalid_outcome,
    :conflicting_event_id,
    :conflicting_evaluation,
    :conflicting_definition
  ]

  @derive Jason.Encoder
  @enforce_keys [:outcome_id]
  defstruct [
    :outcome_id,
    :description,
    :definition,
    evaluations: [],
    status: :pending,
    issues: []
  ]

  @type issue ::
          :unknown_result
          | :missing_event_id
          | :invalid_iteration
          | :invalid_description
          | :invalid_explanation
          | :invalid_processed_at
          | :invalid_start_event_id
          | :invalid_evaluation
          | :invalid_outcome
          | :conflicting_event_id
          | :conflicting_evaluation
          | :conflicting_definition
  @type status :: :pending | OutcomeEvaluation.result()
  @typedoc "The provider's first definition echo, verbatim; its keys and values are not interpreted here."
  @type definition :: map()
  @type t :: %__MODULE__{
          outcome_id: String.t(),
          description: String.t() | nil,
          definition: definition() | nil,
          evaluations: [OutcomeEvaluation.t()],
          status: status(),
          issues: [issue()]
        }

  @doc "The closed set of diagnostic atoms an outcome may carry."
  @spec issues() :: [issue()]
  def issues, do: @issues

  @doc "The issues that make `status` `:unknown` whatever the evaluations say."
  @spec poisoning_issues() :: [issue()]
  def poisoning_issues, do: @poisoning_issues

  @doc """
  Validates a closed atom-keyed attribute map or an existing struct, then
  derives `status` and the order of `evaluations`.

  Nested evaluations must be `OutcomeEvaluation` structs for this outcome;
  each is re-validated.
  """
  @spec new(map() | t()) :: {:ok, t()} | {:error, {:invalid_outcome_result, atom()}}
  def new(%__MODULE__{} = outcome),
    do: new(Map.delete(Map.from_struct(outcome), :status))

  def new(%{} = attrs) do
    with :ok <- validate(attrs),
         {:ok, evaluations} <- revalidate(attrs) do
      {ordered, derived} = order(evaluations)
      issues = Enum.uniq(Map.get(attrs, :issues, []) ++ derived)

      {:ok,
       %__MODULE__{
         outcome_id: attrs.outcome_id,
         description: Map.get(attrs, :description),
         definition: Map.get(attrs, :definition),
         evaluations: ordered,
         status: status(ordered, issues),
         issues: issues
       }}
    end
  end

  def new(_other), do: invalid(:outcome_result)

  defp validate(attrs) do
    cond do
      Map.keys(attrs) -- @keys != [] -> invalid(:keys)
      not nonempty_binary?(Map.get(attrs, :outcome_id)) -> invalid(:outcome_id)
      not optional_binary?(Map.get(attrs, :description)) -> invalid(:description)
      not valid_definition?(Map.get(attrs, :definition)) -> invalid(:definition)
      not valid_issues?(Map.get(attrs, :issues, [])) -> invalid(:issues)
      true -> :ok
    end
  end

  defp revalidate(%{outcome_id: id} = attrs) do
    case Map.get(attrs, :evaluations, []) do
      list when is_list(list) -> revalidate_each(list, id, [])
      _other -> invalid(:evaluations)
    end
  end

  defp revalidate_each([], _id, acc), do: {:ok, Enum.reverse(acc)}

  defp revalidate_each([%OutcomeEvaluation{outcome_id: id} = evaluation | rest], id, acc) do
    case OutcomeEvaluation.new(evaluation) do
      {:ok, valid} -> revalidate_each(rest, id, [valid | acc])
      {:error, _reason} -> invalid(:evaluations)
    end
  end

  defp revalidate_each(_other, _id, _acc), do: invalid(:evaluations)

  defp order(evaluations) do
    {nil_iteration, iterated} = Enum.split_with(evaluations, &is_nil(&1.iteration))
    sorted = Enum.sort_by(iterated, & &1.iteration)
    iterations = Enum.map(sorted, & &1.iteration)

    derived =
      Enum.filter(
        [
          {:invalid_iteration, nil_iteration != []},
          {:conflicting_evaluation, Enum.uniq(iterations) != iterations}
        ],
        &elem(&1, 1)
      )

    {sorted ++ nil_iteration, Enum.map(derived, &elem(&1, 0))}
  end

  defp status(evaluations, issues) do
    cond do
      Enum.any?(issues, &(&1 in @poisoning_issues)) -> :unknown
      evaluations == [] -> :pending
      true -> List.last(evaluations).result
    end
  end

  defp nonempty_binary?(value), do: is_binary(value) and value != ""
  defp optional_binary?(value), do: is_nil(value) or is_binary(value)
  defp valid_definition?(value), do: is_nil(value) or (is_map(value) and not is_struct(value))
  defp valid_issues?(issues), do: proper_list?(issues) and Enum.all?(issues, &(&1 in @issues))

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false
  defp invalid(reason), do: {:error, {:invalid_outcome_result, reason}}
end
