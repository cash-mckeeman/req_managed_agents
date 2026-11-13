defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Grading do
  @moduledoc """
  Projects Claude Managed Agents outcome events into `OutcomeResult` values.

  `outcome_results/1` is pure and total: it takes any term, never raises and
  never creates atoms from provider strings. It returns one result per
  `outcome_id` in first-observation order, built only from the definition,
  evaluation-start, evaluation-ongoing and evaluation-end events that carry a
  nonempty binary `outcome_id`; everything else is ignored.

  Only end events become evaluations, and only their `result` key is read as the
  verdict, never `verdict` or an idle stop reason. Malformed fields are
  normalized to nil and reported through the result's `issues`. Replayed events
  (same id, same payload) collapse; conflicting ids, iterations or definitions
  are retained and make the aggregate `:unknown`. `status` and evaluation order
  are derived by `OutcomeResult.new/1`.
  """

  alias ReqManagedAgents.{OutcomeEvaluation, OutcomeResult}

  @verdicts %{
    "satisfied" => :satisfied,
    "needs_revision" => :needs_revision,
    "max_iterations_reached" => :max_iterations_reached,
    "failed" => :failed,
    "interrupted" => :interrupted
  }

  @doc "Projects the outcome events in `events`, in first-observation order."
  @spec outcome_results([term()]) :: [OutcomeResult.t()]
  def outcome_results(events) do
    observations = observations(events, [])
    conflicting = conflicting_event_ids(observations)

    observations
    |> dedupe()
    |> group()
    |> Enum.map(fn {id, group} -> build(id, group, conflicting) end)
  end

  defp observations([event | rest], acc) do
    case observation(event) do
      nil -> observations(rest, acc)
      observed -> observations(rest, [observed | acc])
    end
  end

  defp observations(_end_of_list, acc), do: Enum.reverse(acc)

  defp observation(%{"type" => type, "outcome_id" => id} = event)
       when is_binary(id) and id != "" do
    case kind(type) do
      nil -> nil
      kind -> {kind, id, event}
    end
  end

  defp observation(_other), do: nil

  defp kind("user.define_outcome"), do: :definition
  defp kind("span.outcome_evaluation_start"), do: :progress
  defp kind("span.outcome_evaluation_ongoing"), do: :progress
  defp kind("span.outcome_evaluation_end"), do: :evaluation
  defp kind(_other), do: nil

  # Only events whose payload is read take part in event-id conflicts.
  defp conflicting_event_ids(observations) do
    observations
    |> Enum.flat_map(fn {kind, _id, event} -> identified(kind, event) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_id, payloads} -> length(Enum.uniq(payloads)) > 1 end)
    |> MapSet.new(&elem(&1, 0))
  end

  defp identified(:progress, _event), do: []

  defp identified(_kind, event) do
    case event_id(event) do
      nil -> []
      id -> [{id, event}]
    end
  end

  defp event_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp event_id(_event), do: nil

  # Without an event id there is no safe identity, so nothing collapses.
  defp dedupe(observations) do
    {kept, _seen} =
      Enum.reduce(observations, {[], MapSet.new()}, fn {kind, _id, event} = observed,
                                                       {kept, seen} ->
        key = {kind, event}

        if kind != :progress and event_id(event) != nil and MapSet.member?(seen, key),
          do: {kept, seen},
          else: {[observed | kept], MapSet.put(seen, key)}
      end)

    Enum.reverse(kept)
  end

  defp group(observations) do
    order = Enum.uniq(Enum.map(observations, &elem(&1, 1)))
    by_id = Enum.group_by(observations, &elem(&1, 1), fn {kind, _id, event} -> {kind, event} end)
    Enum.map(order, &{&1, Map.fetch!(by_id, &1)})
  end

  defp build(id, group, conflicting) do
    definitions = for {:definition, event} <- group, do: event
    ends = for {:evaluation, event} <- group, do: event

    {description, definition, definition_issues} = definition(definitions)
    {evaluations, evaluation_issues} = evaluations(id, ends)
    id_issues = id_conflict(definitions ++ ends, conflicting)

    attrs = %{
      outcome_id: id,
      description: description,
      definition: definition,
      evaluations: evaluations,
      issues: id_issues ++ definition_issues ++ evaluation_issues
    }

    case OutcomeResult.new(attrs) do
      {:ok, result} -> result
      {:error, _reason} -> fallback(id)
    end
  end

  defp fallback(id) do
    {:ok, result} = OutcomeResult.new(%{outcome_id: id, issues: [:invalid_outcome]})
    result
  end

  defp id_conflict(events, conflicting) do
    if Enum.any?(events, &MapSet.member?(conflicting, event_id(&1))),
      do: [:conflicting_event_id],
      else: []
  end

  defp definition([]), do: {nil, nil, []}

  defp definition([first | _] = definitions) do
    {description, issues} = optional_binary(Map.get(first, "description"), :invalid_description)

    conflict =
      if Enum.any?(definitions, &(semantics(&1) != semantics(first))),
        do: [:conflicting_definition],
        else: []

    {description, first, issues ++ conflict}
  end

  defp semantics(event),
    do:
      {Map.get(event, "description"), Map.get(event, "rubric"), Map.get(event, "max_iterations")}

  defp evaluations(id, ends) do
    Enum.reduce(ends, {[], []}, fn event, {evaluations, issues} ->
      case evaluation(id, event) do
        {:ok, evaluation, found} -> {evaluations ++ [evaluation], issues ++ found}
        {:error, found} -> {evaluations, issues ++ found}
      end
    end)
  end

  defp evaluation(id, event) do
    {event_id, id_issues} = event_id_field(event)

    {start_id, start_issues} =
      optional_binary(Map.get(event, "outcome_evaluation_start_id"), :invalid_start_event_id)

    {iteration, iteration_issues} = iteration(Map.get(event, "iteration"))
    {result, result_issues} = result(Map.get(event, "result"))

    {explanation, explanation_issues} =
      optional_binary(Map.get(event, "explanation"), :invalid_explanation)

    {processed_at, processed_issues} =
      optional_binary(Map.get(event, "processed_at"), :invalid_processed_at)

    issues =
      id_issues ++
        start_issues ++
        iteration_issues ++ result_issues ++ explanation_issues ++ processed_issues

    attrs = %{
      outcome_id: id,
      event_id: event_id,
      start_event_id: start_id,
      iteration: iteration,
      result: result,
      explanation: explanation,
      processed_at: processed_at,
      raw: event
    }

    case OutcomeEvaluation.new(attrs) do
      {:ok, evaluation} -> {:ok, evaluation, issues}
      {:error, _reason} -> {:error, [:invalid_evaluation | issues]}
    end
  end

  defp event_id_field(event) do
    case event_id(event) do
      nil -> {nil, [:missing_event_id]}
      id -> {id, []}
    end
  end

  defp optional_binary(nil, _issue), do: {nil, []}
  defp optional_binary(value, _issue) when is_binary(value), do: {value, []}
  defp optional_binary(_value, issue), do: {nil, [issue]}

  defp iteration(value) when is_integer(value) and value >= 0, do: {value, []}
  defp iteration(_value), do: {nil, [:invalid_iteration]}

  defp result(value) when is_binary(value) do
    case Map.fetch(@verdicts, value) do
      {:ok, verdict} -> {verdict, []}
      :error -> {:unknown, [:unknown_result]}
    end
  end

  defp result(_value), do: {:unknown, [:unknown_result]}
end
