defmodule ReqManagedAgents.OutcomeResultTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.{OutcomeEvaluation, OutcomeResult}

  defp invalid(reason), do: {:error, {:invalid_outcome_result, reason}}

  defp evaluation(iteration, result, extra \\ %{}) do
    attrs = Map.merge(%{outcome_id: "outc-1", iteration: iteration, result: result}, extra)
    {:ok, evaluation} = OutcomeEvaluation.new(attrs)
    evaluation
  end

  defp build(evaluations, issues \\ []) do
    OutcomeResult.new(%{outcome_id: "outc-1", evaluations: evaluations, issues: issues})
  end

  describe "new/1" do
    test "derives the aggregate from the evaluations" do
      {:ok, evaluation} =
        OutcomeEvaluation.new(%{
          outcome_id: "outc-1",
          event_id: "eval-1",
          iteration: 0,
          result: :needs_revision,
          explanation: "Missing total",
          raw: %{"usage" => %{}}
        })

      assert {:ok, outcome} =
               OutcomeResult.new(%{outcome_id: "outc-1", evaluations: [evaluation]})

      assert outcome.status == :needs_revision

      assert {:ok, %OutcomeResult{status: :pending, evaluations: [], issues: []}} =
               OutcomeResult.new(%{outcome_id: "outc-1"})

      assert {:ok, %OutcomeResult{status: :needs_revision}} =
               OutcomeResult.new(%{outcome | status: :satisfied})
    end

    test "rejects a supplied aggregate as an unknown key" do
      assert OutcomeResult.new(%{outcome_id: "outc-1", status: :satisfied}) == invalid(:keys)
      assert OutcomeResult.new(%{outcome_id: "outc-1", extra: 1}) == invalid(:keys)
    end

    test "defaults and keeps description and definition" do
      assert {:ok, %OutcomeResult{description: nil, definition: nil}} =
               OutcomeResult.new(%{outcome_id: "o"})

      definition = %{"description" => "d", "rubric" => %{"x" => 1}}

      assert {:ok, %OutcomeResult{description: "d", definition: ^definition}} =
               OutcomeResult.new(%{outcome_id: "o", description: "d", definition: definition})
    end

    test "rejects invalid fields" do
      cases = [
        {%{}, :outcome_id},
        {%{outcome_id: ""}, :outcome_id},
        {%{outcome_id: 1}, :outcome_id},
        {%{outcome_id: "o", description: 1}, :description},
        {%{outcome_id: "o", definition: "x"}, :definition},
        {%{outcome_id: "o", definition: [%{}]}, :definition},
        {%{outcome_id: "o", definition: URI.parse("x")}, :definition},
        {%{outcome_id: "o", evaluations: nil}, :evaluations},
        {%{outcome_id: "o", evaluations: [%{outcome_id: "o"}]}, :evaluations},
        {%{outcome_id: "o", issues: nil}, :issues},
        {%{outcome_id: "o", issues: [:bogus]}, :issues},
        {%{outcome_id: "o", issues: ["unknown_result"]}, :issues},
        {%{outcome_id: "o", issues: [:unknown_result | :unknown_result]}, :issues}
      ]

      for {attrs, reason} <- cases do
        assert OutcomeResult.new(attrs) == invalid(reason), inspect(attrs)
      end
    end

    test "rejects non-map input with the type's own name" do
      assert OutcomeResult.new("outc-1") == invalid(:outcome_result)
      assert OutcomeResult.new(nil) == invalid(:outcome_result)
    end

    test "rejects an evaluation for another outcome" do
      assert OutcomeResult.new(%{outcome_id: "outc-2", evaluations: [evaluation(0, :failed)]}) ==
               invalid(:evaluations)
    end

    test "rejects a nested plain map even when it would be valid" do
      assert OutcomeResult.new(%{
               outcome_id: "outc-1",
               evaluations: [%{outcome_id: "outc-1", iteration: 0, result: :failed}]
             }) == invalid(:evaluations)
    end

    test "revalidates nested evaluation structs" do
      bad = %{evaluation(0, :failed) | iteration: -3}
      assert build([bad]) == invalid(:evaluations)
    end

    test "revalidates an existing struct, recomputing status and order" do
      {:ok, outcome} = build([evaluation(1, :satisfied), evaluation(0, :needs_revision)])
      assert OutcomeResult.new(outcome) == {:ok, outcome}

      assert {:ok, %OutcomeResult{status: :satisfied}} =
               OutcomeResult.new(%{outcome | status: :failed})

      assert {:ok, %OutcomeResult{status: :satisfied, evaluations: [%{iteration: 0}, _]}} =
               OutcomeResult.new(%{outcome | evaluations: Enum.reverse(outcome.evaluations)})

      assert OutcomeResult.new(%{outcome | description: 4}) == invalid(:description)
      assert OutcomeResult.new(%{outcome | issues: [:nope]}) == invalid(:issues)
      assert OutcomeResult.new(%{outcome | outcome_id: ""}) == invalid(:outcome_id)
    end
  end

  describe "derivation" do
    test "orders evaluations by iteration and takes the greatest iteration's verdict" do
      assert {:ok, outcome} = build([evaluation(1, :satisfied), evaluation(0, :needs_revision)])
      assert Enum.map(outcome.evaluations, & &1.iteration) == [0, 1]
      assert outcome.status == :satisfied
      assert outcome.issues == []
    end

    test "an unknown result below a known iteration does not mask it" do
      assert {:ok, %OutcomeResult{status: :satisfied}} =
               build([evaluation(0, :unknown), evaluation(1, :satisfied)])
    end

    test "an unknown result at the greatest iteration is unknown" do
      assert {:ok, %OutcomeResult{status: :unknown, issues: []}} =
               build([evaluation(0, :satisfied), evaluation(1, :unknown)])
    end

    test "every provider verdict at the greatest iteration is the status" do
      for verdict <- [:satisfied, :needs_revision, :max_iterations_reached, :failed, :interrupted] do
        assert {:ok, %OutcomeResult{status: ^verdict}} = build([evaluation(0, verdict)])
      end
    end

    test "a nil iteration is unknown and flagged, ordered last" do
      assert {:ok, outcome} = build([evaluation(nil, :satisfied), evaluation(0, :satisfied)])
      assert outcome.status == :unknown
      assert outcome.issues == [:invalid_iteration]
      assert Enum.map(outcome.evaluations, & &1.iteration) == [0, nil]
    end

    test "nil-iteration evaluations keep their input order after the iterated ones" do
      assert {:ok, outcome} =
               build([
                 evaluation(nil, :failed, %{event_id: "x"}),
                 evaluation(0, :satisfied, %{event_id: "a"}),
                 evaluation(nil, :failed, %{event_id: "y"})
               ])

      assert Enum.map(outcome.evaluations, & &1.event_id) == ["a", "x", "y"]
    end

    test "a shared iteration is unknown and flagged, keeping input order for ties" do
      first = evaluation(0, :satisfied, %{event_id: "a"})
      second = evaluation(0, :satisfied, %{event_id: "b"})
      assert {:ok, outcome} = build([second, first])
      assert outcome.status == :unknown
      assert outcome.issues == [:conflicting_evaluation]
      assert Enum.map(outcome.evaluations, & &1.event_id) == ["b", "a"]
    end

    test "each poisoning issue makes the status unknown" do
      for issue <- OutcomeResult.poisoning_issues() do
        assert {:ok, %OutcomeResult{status: :unknown, issues: [^issue]}} =
                 build([evaluation(0, :satisfied)], [issue])
      end
    end

    test "non-poisoning issues leave the verdict intact" do
      for issue <- OutcomeResult.issues() -- OutcomeResult.poisoning_issues() do
        assert {:ok, %OutcomeResult{status: :satisfied}} =
                 build([evaluation(0, :satisfied)], [issue])
      end

      assert :unknown_result in (OutcomeResult.issues() -- OutcomeResult.poisoning_issues())
    end

    test "poisoning issues also make an evaluation-less outcome unknown" do
      assert {:ok, %OutcomeResult{status: :unknown}} = build([], [:invalid_outcome])
    end

    test "duplicate issues collapse to the first occurrence" do
      assert {:ok, outcome} =
               build([evaluation(nil, :failed)], [
                 :unknown_result,
                 :invalid_iteration,
                 :unknown_result,
                 :invalid_iteration
               ])

      assert outcome.issues == [:unknown_result, :invalid_iteration]
    end
  end

  test "issue vocabulary is the closed set of twelve" do
    assert length(OutcomeResult.issues()) == 12
    assert Enum.uniq(OutcomeResult.issues()) == OutcomeResult.issues()
    assert OutcomeResult.poisoning_issues() -- OutcomeResult.issues() == []

    assert Enum.sort(OutcomeResult.poisoning_issues()) ==
             Enum.sort([
               :invalid_iteration,
               :invalid_evaluation,
               :invalid_outcome,
               :conflicting_event_id,
               :conflicting_evaluation,
               :conflicting_definition
             ])
  end

  test "outcome_id is enforced and status defaults to pending" do
    assert_raise ArgumentError, fn -> struct!(OutcomeResult, %{}) end
    assert %OutcomeResult{outcome_id: "o"}.status == :pending
  end

  test "encodes to JSON, nesting evaluations and keeping raw provider fields" do
    {:ok, outcome} =
      OutcomeResult.new(%{
        outcome_id: "outc-1",
        definition: %{"rubric" => %{"type" => "text"}},
        evaluations: [evaluation(0, :needs_revision, %{raw: %{"vendor" => "x"}})]
      })

    decoded = Jason.decode!(Jason.encode!(outcome))
    assert decoded["status"] == "needs_revision"
    assert decoded["issues"] == []
    assert decoded["definition"] == %{"rubric" => %{"type" => "text"}}
    assert [%{"result" => "needs_revision", "raw" => %{"vendor" => "x"}}] = decoded["evaluations"]
  end
end
