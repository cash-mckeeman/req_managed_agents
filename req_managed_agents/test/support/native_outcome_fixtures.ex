defmodule ReqManagedAgents.Test.NativeOutcomeFixtures do
  @moduledoc """
  Synthetic outcome events built to the documented Claude Managed Agents event
  shape. They are not live captures.

  Every default carries a stable unique id, an RFC3339 `processed_at`, the
  documented `result` key, an outcome id and an explanation. Malformed variants
  are made by the caller with explicit `Map` operations on these maps.
  """

  @type event :: %{required(String.t()) => term()}

  @doc "A `user.define_outcome` echo. Options: `:id`, `:description`, `:rubric`, `:max_iterations`, `:processed_at`."
  @spec definition(String.t(), keyword()) :: event()
  def definition(outcome_id, opts \\ []) do
    %{
      "type" => "user.define_outcome",
      "id" => Keyword.get(opts, :id, "def-#{outcome_id}"),
      "outcome_id" => outcome_id,
      "description" => Keyword.get(opts, :description, "Build the report"),
      "rubric" => Keyword.get(opts, :rubric, %{"type" => "text", "content" => "- has a total"}),
      "max_iterations" => Keyword.get(opts, :max_iterations, 3),
      "processed_at" => Keyword.get(opts, :processed_at, "2026-11-08T10:00:00Z")
    }
  end

  @doc "A `span.outcome_evaluation_end`. Options: `:id`, `:explanation`, `:start_id`, `:processed_at`."
  @spec evaluation(String.t(), non_neg_integer(), String.t() | atom(), keyword()) :: event()
  def evaluation(outcome_id, iteration, result, opts \\ []) do
    %{
      "type" => "span.outcome_evaluation_end",
      "id" => Keyword.get(opts, :id, "end-#{outcome_id}-#{iteration}"),
      "outcome_id" => outcome_id,
      "outcome_evaluation_start_id" =>
        Keyword.get(opts, :start_id, "start-#{outcome_id}-#{iteration}"),
      "iteration" => iteration,
      "result" => to_string(result),
      "explanation" => Keyword.get(opts, :explanation, "Explanation #{iteration}"),
      "processed_at" => Keyword.get(opts, :processed_at, "2026-11-08T10:01:00Z")
    }
  end

  @doc "A `span.outcome_evaluation_start`."
  @spec start(String.t(), non_neg_integer()) :: event()
  def start(outcome_id, iteration) do
    %{
      "type" => "span.outcome_evaluation_start",
      "id" => "start-#{outcome_id}-#{iteration}",
      "outcome_id" => outcome_id,
      "iteration" => iteration,
      "processed_at" => "2026-11-08T10:00:30Z"
    }
  end

  @doc "A `span.outcome_evaluation_ongoing` heartbeat."
  @spec ongoing(String.t(), non_neg_integer()) :: event()
  def ongoing(outcome_id, iteration) do
    %{
      "type" => "span.outcome_evaluation_ongoing",
      "id" => "ongoing-#{outcome_id}-#{iteration}",
      "outcome_id" => outcome_id,
      "iteration" => iteration,
      "processed_at" => "2026-11-08T10:00:45Z"
    }
  end

  @doc "A `session.status_idle` event with the given stop reason type."
  @spec idle(String.t()) :: event()
  def idle(reason \\ "end_turn") do
    %{
      "type" => "session.status_idle",
      "id" => "idle-#{reason}",
      "stop_reason" => %{"type" => reason},
      "processed_at" => "2026-11-08T10:02:00Z"
    }
  end

  @doc "One outcome (`\"outc-1\"`) that needs revision at iteration 0 and is satisfied at iteration 1."
  @spec happy() :: [event()]
  def happy do
    [
      definition("outc-1"),
      start("outc-1", 0),
      ongoing("outc-1", 0),
      evaluation("outc-1", 0, :needs_revision, explanation: "Missing total"),
      start("outc-1", 1),
      evaluation("outc-1", 1, :satisfied, explanation: "Criteria met"),
      idle()
    ]
  end
end
