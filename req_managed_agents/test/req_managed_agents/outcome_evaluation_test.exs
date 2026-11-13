defmodule ReqManagedAgents.OutcomeEvaluationTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.OutcomeEvaluation

  @verdicts [
    :satisfied,
    :needs_revision,
    :max_iterations_reached,
    :failed,
    :interrupted,
    :unknown
  ]

  defp invalid(reason), do: {:error, {:invalid_outcome_evaluation, reason}}

  describe "new/1" do
    test "accepts a full attribute map" do
      raw = %{"usage" => %{}, "extra" => 1}

      assert {:ok, %OutcomeEvaluation{} = evaluation} =
               OutcomeEvaluation.new(%{
                 outcome_id: "outc-1",
                 event_id: "eval-1",
                 start_event_id: "",
                 iteration: 0,
                 result: :needs_revision,
                 explanation: "Missing total",
                 processed_at: "2026-11-08T00:00:00Z",
                 raw: raw
               })

      assert evaluation.outcome_id == "outc-1"
      assert evaluation.start_event_id == ""
      assert evaluation.iteration == 0
      assert evaluation.result == :needs_revision
      assert evaluation.raw == raw
    end

    test "defaults optional fields" do
      assert {:ok, evaluation} = OutcomeEvaluation.new(%{outcome_id: "outc-1"})

      assert %OutcomeEvaluation{
               outcome_id: "outc-1",
               event_id: nil,
               start_event_id: nil,
               iteration: nil,
               result: :unknown,
               explanation: nil,
               processed_at: nil,
               raw: %{}
             } = evaluation
    end

    test "accepts every known verdict" do
      for verdict <- @verdicts do
        assert {:ok, %OutcomeEvaluation{result: ^verdict}} =
                 OutcomeEvaluation.new(%{outcome_id: "o", result: verdict})
      end
    end

    test "accepts nil for nullable fields" do
      assert {:ok, _} =
               OutcomeEvaluation.new(%{
                 outcome_id: "o",
                 event_id: nil,
                 start_event_id: nil,
                 iteration: nil,
                 explanation: nil,
                 processed_at: nil
               })
    end

    test "revalidates an existing struct" do
      {:ok, evaluation} = OutcomeEvaluation.new(%{outcome_id: "o", iteration: 2})
      assert OutcomeEvaluation.new(evaluation) == {:ok, evaluation}
      assert OutcomeEvaluation.new(%{evaluation | iteration: -1}) == invalid(:iteration)
      assert OutcomeEvaluation.new(%{evaluation | result: :nope}) == invalid(:result)
      assert OutcomeEvaluation.new(%{evaluation | raw: [1]}) == invalid(:raw)
    end

    test "rejects invalid input" do
      cases = [
        {%{}, :outcome_id},
        {%{outcome_id: ""}, :outcome_id},
        {%{outcome_id: nil}, :outcome_id},
        {%{outcome_id: :o}, :outcome_id},
        {%{outcome_id: "o", event_id: 1}, :event_id},
        {%{outcome_id: "o", start_event_id: :a}, :start_event_id},
        {%{outcome_id: "o", iteration: -1}, :iteration},
        {%{outcome_id: "o", iteration: 1.0}, :iteration},
        {%{outcome_id: "o", iteration: "1"}, :iteration},
        {%{outcome_id: "o", result: "satisfied"}, :result},
        {%{outcome_id: "o", result: :pending}, :result},
        {%{outcome_id: "o", explanation: 3}, :explanation},
        {%{outcome_id: "o", processed_at: 3}, :processed_at},
        {%{outcome_id: "o", raw: nil}, :raw},
        {%{outcome_id: "o", raw: [%{}]}, :raw},
        {%{outcome_id: "o", raw: URI.parse("x")}, :raw},
        {%{outcome_id: "o", extra: 1}, :keys},
        {%{"outcome_id" => "o"}, :keys}
      ]

      for {attrs, reason} <- cases do
        assert OutcomeEvaluation.new(attrs) == invalid(reason), inspect(attrs)
      end
    end

    test "rejects non-map input with the type's own name" do
      assert OutcomeEvaluation.new("outc-1") == invalid(:outcome_evaluation)
      assert OutcomeEvaluation.new(nil) == invalid(:outcome_evaluation)
      assert OutcomeEvaluation.new(outcome_id: "o") == invalid(:outcome_evaluation)
    end
  end

  test "outcome_id is enforced" do
    assert_raise ArgumentError, fn -> struct!(OutcomeEvaluation, %{}) end
  end

  test "encodes to JSON with provider extension fields retained" do
    {:ok, evaluation} =
      OutcomeEvaluation.new(%{
        outcome_id: "outc-1",
        iteration: 0,
        result: :needs_revision,
        raw: %{"usage" => %{"input_tokens" => 3}, "vendor" => "x"}
      })

    decoded = Jason.decode!(Jason.encode!(evaluation))
    assert decoded["result"] == "needs_revision"
    assert decoded["outcome_id"] == "outc-1"
    assert decoded["raw"] == %{"usage" => %{"input_tokens" => 3}, "vendor" => "x"}
  end
end
