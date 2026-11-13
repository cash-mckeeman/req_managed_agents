defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.GradingTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.OutcomeResult
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Grading
  alias ReqManagedAgents.Test.NativeOutcomeFixtures, as: Fixtures

  defp one(events) do
    assert [%OutcomeResult{} = outcome] = Grading.outcome_results(events)
    outcome
  end

  defp results(outcome), do: Enum.map(outcome.evaluations, & &1.result)
  defp iterations(outcome), do: Enum.map(outcome.evaluations, & &1.iteration)

  test "projects a revised-then-satisfied outcome" do
    [outcome] = Grading.outcome_results(Fixtures.happy())
    assert outcome.outcome_id == "outc-1"
    assert outcome.status == :satisfied
    assert Enum.map(outcome.evaluations, & &1.iteration) == [0, 1]
    assert Enum.map(outcome.evaluations, & &1.result) == [:needs_revision, :satisfied]
    assert Enum.map(outcome.evaluations, & &1.explanation) == ["Missing total", "Criteria met"]
    assert outcome.issues == []
  end

  describe "pending and verdict mapping" do
    test "definition, start and heartbeat without an end stay pending" do
      outcome =
        one([Fixtures.definition("o"), Fixtures.start("o", 0), Fixtures.ongoing("o", 0)])

      assert outcome.status == :pending
      assert outcome.evaluations == []
      assert outcome.issues == []
      assert outcome.definition == Fixtures.definition("o")
    end

    test "each documented verdict maps to its atom, and needs_revision is only a grade" do
      for {wire, atom} <- [
            {"satisfied", :satisfied},
            {"needs_revision", :needs_revision},
            {"max_iterations_reached", :max_iterations_reached},
            {"failed", :failed},
            {"interrupted", :interrupted}
          ] do
        outcome = one([Fixtures.evaluation("o", 0, wire)])
        assert results(outcome) == [atom]
        assert outcome.status == atom
        assert outcome.issues == []
      end
    end

    test "evaluation-only history keeps id and verdict with no definition" do
      outcome = one([Fixtures.evaluation("o", 0, :failed)])
      assert outcome.outcome_id == "o"
      assert outcome.status == :failed
      assert outcome.description == nil
      assert outcome.definition == nil
    end

    test "a start or heartbeat after a completed evaluation keeps the verdict" do
      outcome =
        one([
          Fixtures.evaluation("o", 0, :needs_revision),
          Fixtures.start("o", 1),
          Fixtures.ongoing("o", 1)
        ])

      assert outcome.status == :needs_revision
      assert results(outcome) == [:needs_revision]
    end

    test "an interrupted evaluation before its start keeps the empty start id" do
      outcome = one([Fixtures.evaluation("o", 0, :interrupted, start_id: "")])
      assert [%{start_event_id: "", result: :interrupted}] = outcome.evaluations
      assert outcome.issues == []
    end
  end

  describe "grouping, replay and ordering" do
    test "interleaved outcomes form independent groups in first-observation order" do
      events = [
        Fixtures.definition("b"),
        Fixtures.evaluation("a", 0, :failed),
        Fixtures.evaluation("b", 0, :satisfied),
        Fixtures.start("a", 1)
      ]

      assert [b, a] = Grading.outcome_results(events)
      assert {b.outcome_id, b.status} == {"b", :satisfied}
      assert {a.outcome_id, a.status} == {"a", :failed}
    end

    test "groups are ordered by the first observation of each outcome, not the last" do
      events = [
        Fixtures.definition("a"),
        Fixtures.definition("b"),
        Fixtures.evaluation("a", 0, :satisfied)
      ]

      assert Enum.map(Grading.outcome_results(events), & &1.outcome_id) == ["a", "b"]
    end

    test "an identical repeated end event yields one evaluation and no conflict" do
      end0 = Fixtures.evaluation("o", 0, :satisfied)
      outcome = one([end0, end0])
      assert length(outcome.evaluations) == 1
      assert outcome.issues == []
    end

    test "a replayed list equals a single pass" do
      assert Grading.outcome_results(Fixtures.happy() ++ Fixtures.happy()) ==
               Grading.outcome_results(Fixtures.happy())
    end

    test "unrelated events interleaved do not change the projection" do
      noise = [
        %{"type" => "agent.message", "id" => "m1", "content" => []},
        %{"type" => "agent.custom_tool_use", "id" => "t1", "name" => "x"},
        Fixtures.idle("requires_action")
      ]

      [head | tail] = Fixtures.happy()
      noisy = [head] ++ noise ++ Enum.intersperse(tail, hd(noise)) ++ noise

      assert Grading.outcome_results(noisy) == Grading.outcome_results(Fixtures.happy())
    end

    test "a late older iteration is sorted and cannot regress the aggregate" do
      outcome =
        one([
          Fixtures.evaluation("o", 1, :satisfied),
          Fixtures.evaluation("o", 0, :needs_revision)
        ])

      assert iterations(outcome) == [0, 1]
      assert outcome.status == :satisfied
      assert outcome.issues == []
    end

    test "start and heartbeat after a completed evaluation do not duplicate or reorder" do
      outcome = one(Fixtures.happy() ++ [Fixtures.ongoing("outc-1", 2)])
      assert iterations(outcome) == [0, 1]
      assert outcome.status == :satisfied
    end
  end

  describe "conflicts" do
    test "the same event id with a different payload keeps both and poisons the aggregate" do
      first = Fixtures.evaluation("o", 0, :satisfied, id: "e1")
      second = Map.put(first, "explanation", "changed")
      outcome = one([first, second])
      assert length(outcome.evaluations) == 2
      assert :conflicting_event_id in outcome.issues
      assert outcome.status == :unknown
    end

    test "the same event id under different outcome ids poisons both outcomes" do
      first = Fixtures.evaluation("a", 0, :satisfied, id: "shared")
      second = Fixtures.evaluation("b", 0, :satisfied, id: "shared")
      assert [a, b] = Grading.outcome_results([first, second])

      for outcome <- [a, b] do
        assert outcome.status == :unknown
        assert :conflicting_event_id in outcome.issues
        assert length(outcome.evaluations) == 1
      end
    end

    test "distinct end ids at one iteration conflict even when the verdicts match" do
      outcome =
        one([
          Fixtures.evaluation("o", 0, :satisfied, id: "e1"),
          Fixtures.evaluation("o", 0, :satisfied, id: "e2")
        ])

      assert length(outcome.evaluations) == 2
      assert :conflicting_evaluation in outcome.issues
      refute :conflicting_event_id in outcome.issues
      assert outcome.status == :unknown
    end

    test "a start sharing an id with an end adds no conflict" do
      start = Fixtures.start("o", 0)

      outcome =
        one([
          start,
          Fixtures.evaluation("o", 0, :satisfied, id: start["id"])
        ])

      assert outcome.issues == []
      assert outcome.status == :satisfied
    end

    test "equal definitions with different ids and times do not conflict" do
      outcome =
        one([
          Fixtures.definition("o"),
          Fixtures.definition("o", id: "def-2", processed_at: "2026-11-08T11:00:00Z"),
          Fixtures.evaluation("o", 0, :satisfied)
        ])

      assert outcome.issues == []
      assert outcome.status == :satisfied
      assert outcome.definition == Fixtures.definition("o")
    end

    test "a changed description, rubric or max_iterations keeps the first definition and poisons" do
      for changed <- [
            [description: "Another goal"],
            [rubric: %{"type" => "text", "content" => "- other"}],
            [max_iterations: 9]
          ] do
        outcome =
          one([
            Fixtures.definition("o"),
            Fixtures.definition("o", [id: "def-2"] ++ changed),
            Fixtures.evaluation("o", 0, :satisfied)
          ])

        assert outcome.definition == Fixtures.definition("o")
        assert outcome.description == "Build the report"
        assert :conflicting_definition in outcome.issues
        assert outcome.status == :unknown
      end
    end

    test "end events without ids keep both iterations and are never deduplicated by content" do
      outcome =
        one([
          Map.delete(Fixtures.evaluation("o", 0, :needs_revision), "id"),
          Map.delete(Fixtures.evaluation("o", 1, :satisfied), "id")
        ])

      assert iterations(outcome) == [0, 1]
      assert outcome.issues == [:missing_event_id]
      assert outcome.status == :satisfied
    end

    test "two id-less ends at one iteration conflict" do
      end0 = Map.delete(Fixtures.evaluation("o", 0, :satisfied), "id")
      outcome = one([end0, end0])
      assert length(outcome.evaluations) == 2
      assert :missing_event_id in outcome.issues
      assert :conflicting_evaluation in outcome.issues
      assert outcome.status == :unknown
    end
  end

  describe "unknown and malformed results" do
    test "an unknown, missing, mistyped or legacy-keyed result is the unknown verdict" do
      base = Fixtures.evaluation("o", 0, :satisfied)

      for event <- [
            Map.put(base, "result", "something_new"),
            Map.delete(base, "result"),
            Map.put(base, "result", 3),
            Map.put(base, "result", :satisfied),
            Map.put(Map.delete(base, "result"), "verdict", "satisfied")
          ] do
        outcome = one([event, Fixtures.idle("end_turn")])
        assert [%{result: :unknown, raw: raw}] = outcome.evaluations
        assert raw == event
        assert outcome.issues == [:unknown_result]
        assert outcome.status == :unknown
      end
    end

    test "an unknown verdict at an older iteration does not mask a later verdict" do
      outcome =
        one([
          Fixtures.evaluation("o", 0, "something_new"),
          Fixtures.evaluation("o", 1, :satisfied)
        ])

      assert outcome.status == :satisfied
      assert outcome.issues == [:unknown_result]
    end

    test "an unknown verdict at the greatest iteration is the aggregate" do
      outcome =
        one([
          Fixtures.evaluation("o", 0, :satisfied),
          Fixtures.evaluation("o", 1, "something_new")
        ])

      assert outcome.status == :unknown
    end

    test "a missing, negative or noninteger iteration is nil and unknown" do
      base = Fixtures.evaluation("o", 0, :satisfied)

      for event <- [
            Map.delete(base, "iteration"),
            Map.put(base, "iteration", -1),
            Map.put(base, "iteration", 1.0),
            Map.put(base, "iteration", "1")
          ] do
        outcome = one([event])
        assert [%{iteration: nil}] = outcome.evaluations
        assert :invalid_iteration in outcome.issues
        assert outcome.status == :unknown
      end
    end

    test "wrongly typed optional fields become nil with their issue; absent nullable fields add none" do
      base = Fixtures.evaluation("o", 0, :satisfied)

      for {key, field, issue} <- [
            {"explanation", :explanation, :invalid_explanation},
            {"processed_at", :processed_at, :invalid_processed_at},
            {"outcome_evaluation_start_id", :start_event_id, :invalid_start_event_id}
          ] do
        outcome = one([Map.put(base, key, 5)])
        assert [evaluation] = outcome.evaluations
        assert Map.get(evaluation, field) == nil
        assert outcome.issues == [issue]
        assert outcome.status == :satisfied

        outcome = one([Map.delete(base, key)])
        assert outcome.issues == []
      end

      outcome = one([Fixtures.definition("o", description: 5)])
      assert outcome.description == nil
      assert outcome.issues == [:invalid_description]

      outcome = one([Map.delete(Fixtures.definition("o"), "description")])
      assert outcome.issues == []
    end

    test "an empty or mistyped end id is nil with :missing_event_id" do
      for id <- ["", 5, nil] do
        outcome = one([Map.put(Fixtures.evaluation("o", 0, :satisfied), "id", id)])
        assert [%{event_id: nil}] = outcome.evaluations
        assert outcome.issues == [:missing_event_id]
      end
    end
  end

  describe "total on arbitrary input" do
    test "non-maps, unrelated types and unidentifiable outcomes are ignored" do
      noise = [
        nil,
        7,
        "span.outcome_evaluation_end",
        [1, 2],
        {:tuple},
        URI.parse("x"),
        %{},
        %{"type" => "agent.message"},
        %{"type" => "span.outcome_evaluation_end"},
        Map.put(Fixtures.evaluation("o", 0, :satisfied), "outcome_id", ""),
        Map.put(Fixtures.evaluation("o", 0, :satisfied), "outcome_id", 4),
        Map.put(Fixtures.definition("o"), "outcome_id", nil)
      ]

      assert Grading.outcome_results(noise) == []
      assert Grading.outcome_results([]) == []
      assert Grading.outcome_results(:not_a_list) == []
      assert Grading.outcome_results([Fixtures.start("o", 0) | :improper]) |> length() == 1
    end

    test "a struct carrying evaluation fields is reported invalid, not raised on" do
      event = Map.merge(%URI{}, Fixtures.evaluation("o", 0, :satisfied))

      assert [%{status: :unknown, issues: [:invalid_evaluation], evaluations: []}] =
               Grading.outcome_results([event])
    end

    test "a struct carrying definition fields is reported invalid, not raised on" do
      event = Map.merge(%URI{}, Fixtures.definition("o"))

      assert [%{status: :unknown, issues: [:invalid_outcome], evaluations: []}] =
               Grading.outcome_results([event])
    end

    @garbage [nil, 7, [1], %{"nested" => 1}, URI.parse("https://example.test")]

    defp end_issue("id", _value), do: :missing_event_id
    defp end_issue("outcome_evaluation_start_id", nil), do: nil
    defp end_issue("outcome_evaluation_start_id", _value), do: :invalid_start_event_id
    defp end_issue("iteration", 7), do: nil
    defp end_issue("iteration", _value), do: :invalid_iteration
    defp end_issue("result", _value), do: :unknown_result
    defp end_issue("explanation", nil), do: nil
    defp end_issue("explanation", _value), do: :invalid_explanation
    defp end_issue("processed_at", nil), do: nil
    defp end_issue("processed_at", _value), do: :invalid_processed_at

    test "every end-event field replaced in turn never raises and reports its issue" do
      base = Fixtures.evaluation("o", 0, :satisfied)

      for {key, _} <- base,
          key not in ["type", "outcome_id"],
          garbage <- @garbage do
        row = inspect({key, garbage})
        outcome = one([Map.put(base, key, garbage)])
        expected = end_issue(key, garbage)

        if expected,
          do: assert(expected in outcome.issues, row),
          else: assert(outcome.issues == [], row)

        want =
          if key == "result" or (key == "iteration" and garbage != 7),
            do: :unknown,
            else: :satisfied

        assert outcome.status == want, row
      end
    end

    test "garbage in start, heartbeat and definition fields adds no issue and keeps a valid verdict" do
      valid_end = Fixtures.evaluation("o", 0, :satisfied)

      quiet = [
        {Fixtures.start("o", 0), ["id", "iteration", "processed_at"]},
        {Fixtures.ongoing("o", 0), ["id", "iteration", "processed_at"]},
        {Fixtures.definition("o"), ["id", "rubric", "max_iterations", "processed_at"]}
      ]

      for {event, keys} <- quiet, key <- keys, garbage <- @garbage do
        outcome = one([Map.put(event, key, garbage), valid_end])
        assert outcome.issues == [], inspect({key, garbage})
        assert outcome.status == :satisfied
      end

      for garbage <- @garbage, garbage != nil do
        outcome = one([Map.put(Fixtures.definition("o"), "description", garbage), valid_end])
        assert outcome.issues == [:invalid_description]
        assert outcome.status == :satisfied
      end
    end

    test "garbage outcome ids and type values identify nothing" do
      events = [
        Fixtures.start("o", 0),
        Fixtures.ongoing("o", 0),
        Fixtures.definition("o"),
        Fixtures.evaluation("o", 0, :satisfied)
      ]

      for event <- events, garbage <- @garbage do
        assert Grading.outcome_results([Map.put(event, "outcome_id", garbage)]) == []
      end

      for event <- events, garbage <- [:"span.outcome_evaluation_end" | @garbage] do
        assert Grading.outcome_results([Map.put(event, "type", garbage)]) == []
      end
    end
  end
end
