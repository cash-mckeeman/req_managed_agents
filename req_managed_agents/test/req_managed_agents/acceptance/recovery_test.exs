defmodule ReqManagedAgents.Acceptance.RecoveryTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Acceptance.Recovery
  alias ReqManagedAgents.Evidence.{Capture, Options, Recorder}

  test "native linked same-argument serial recovery passes with exact record references" do
    capture = capture(events())
    assert {:ok, assertion} = Recovery.assess(capture, "lookup", %{"key" => "value"})
    assert assertion.outcome == :passed
    assert assertion.evidence == Enum.map(capture.records, &(&1.source_id <> ":" <> &1.id))
  end

  test "ambiguous, unrelated and unordered events cannot establish recovery" do
    for {change, index} <-
          Enum.with_index([
            fn e -> List.update_at(e, 2, &Map.put(&1, "input", %{"key" => "other"})) end,
            fn e -> List.update_at(e, 2, &Map.put(&1, "name", "other")) end,
            fn e -> List.update_at(e, 2, &Map.put(&1, "processed_at", time(1))) end,
            fn e -> List.update_at(e, 2, &Map.put(&1, "processed_at", time(0))) end,
            fn e -> List.update_at(e, 2, &Map.delete(&1, "processed_at")) end,
            fn e -> List.update_at(e, 1, &Map.delete(&1, "tool_use_id")) end,
            fn e -> List.update_at(e, 3, &Map.put(&1, "session_id", "different-session")) end,
            fn e -> List.update_at(e, 3, &Map.delete(&1, "is_error")) end,
            fn e -> e ++ [Map.put(Enum.at(e, 1), "id", "ambiguous-result")] end
          ]) do
      assert {:ok, assertion} =
               Recovery.assess(capture(change.(events())), "lookup", %{"key" => "value"})

      assert assertion.outcome == :inconclusive, "case #{index} unexpectedly passed"
    end
  end

  test "same IDs from distinct acquisition sources do not link or pair" do
    {:ok, options} = Options.new(content: :retain)
    {:ok, recorder} = Recorder.start_link(options)
    Recorder.context(recorder, :managed, "session")
    [use1, result1, use2, result2] = events()
    Recorder.native(recorder, use1)
    Recorder.history(recorder, result1)
    Recorder.history(recorder, use2)
    Recorder.native(recorder, result2)
    {:ok, capture} = Recorder.snapshot(recorder)
    GenServer.stop(recorder)
    assert {:ok, assertion} = Recovery.assess(capture, "lookup", %{"key" => "value"})
    assert assertion.outcome == :inconclusive
  end

  test "AgentCore inline tool use without native outcome and ordering remains inconclusive" do
    capture =
      capture(
        [
          %{
            "contentBlockStart" => %{
              "contentBlockIndex" => 0,
              "start" => %{"toolUse" => %{"toolUseId" => "use-one", "name" => "lookup"}}
            }
          }
        ],
        :agentcore
      )

    assert {:ok, assertion} = Recovery.assess(capture, "lookup", %{"key" => "value"})
    assert assertion.outcome == :inconclusive
  end

  test "local or transport observations and dropped arguments cannot establish native recovery" do
    for native <- [
          [],
          [
            %{"type" => "span.model_request_start", "id" => "request-start"},
            %{
              "type" => "span.model_request_end",
              "id" => "request-end",
              "model_request_start_id" => "request-start",
              "is_error" => false
            }
          ]
        ] do
      assert {:ok, assertion} = Recovery.assess(capture(native), "lookup", %{"key" => "value"})
      assert assertion.outcome == :inconclusive
    end

    {:ok, dropped} = Capture.new(capture(events()), content: :drop)
    assert {:ok, assertion} = Recovery.assess(dropped, "lookup", %{"key" => "value"})
    assert assertion.outcome == :inconclusive
  end

  test "equivalent explicit thread identity fields retain the positive control" do
    for payloads <- [
          Enum.map(
            events(),
            &(Map.delete(&1, "session_thread_id") |> Map.put("thread_id", "thread-one"))
          ),
          Enum.map(events(), &Map.put(&1, "thread_id", "thread-one"))
        ] do
      assert {:ok, assertion} = Recovery.assess(capture(payloads), "lookup", %{"key" => "value"})
      assert assertion.outcome == :passed
    end
  end

  test "explicit native thread scope must agree within and across attempts" do
    cases = [
      fn events ->
        List.update_at(events, 1, &Map.put(&1, "session_thread_id", "other-thread"))
      end,
      fn events ->
        Enum.with_index(events)
        |> Enum.map(fn {event, index} ->
          if index >= 2, do: Map.put(event, "session_thread_id", "other-thread"), else: event
        end)
      end,
      fn events ->
        List.update_at(events, 0, &Map.put(&1, "thread_id", "contradictory-thread"))
      end,
      fn events -> Enum.map(events, &Map.delete(&1, "session_thread_id")) end
    ]

    for change <- cases do
      assert {:ok, assertion} =
               Recovery.assess(capture(change.(events())), "lookup", %{"key" => "value"})

      assert assertion.outcome == :inconclusive
    end
  end

  defp events do
    [
      %{
        "type" => "agent.tool_use",
        "id" => "use-one",
        "name" => "lookup",
        "input" => %{"key" => "value"},
        "processed_at" => time(0)
      },
      %{
        "type" => "agent.tool_result",
        "id" => "result-one",
        "tool_use_id" => "use-one",
        "is_error" => true,
        "processed_at" => time(1)
      },
      %{
        "type" => "agent.tool_use",
        "id" => "use-two",
        "name" => "lookup",
        "input" => %{"key" => "value"},
        "processed_at" => time(2)
      },
      %{
        "type" => "agent.tool_result",
        "id" => "result-two",
        "tool_use_id" => "use-two",
        "is_error" => false,
        "processed_at" => time(3)
      }
    ]
    |> Enum.map(&Map.put(&1, "session_thread_id", "thread-one"))
  end

  defp time(second), do: "2026-01-01T00:00:0#{second}Z"

  defp capture(events, provider \\ :managed) do
    {:ok, options} = Options.new(content: :retain)
    {:ok, recorder} = Recorder.start_link(options)
    Recorder.context(recorder, provider, "session")
    Enum.each(events, &Recorder.native(recorder, &1))
    {:ok, capture} = Recorder.snapshot(recorder)
    GenServer.stop(recorder)
    capture
  end
end
