defmodule ReqManagedAgents.Evidence.AdapterTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Evidence.{Capture, NativeObservation, Record}
  alias ReqManagedAgents.Providers.BedrockAgentCore.Evidence, as: Bedrock
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Evidence, as: Claude

  @time "2026-10-08T12:00:00Z"

  test "Claude interpretation keeps safe native facts and diagnoses malformed metadata" do
    payload = %{
      "type" => "agent.message",
      "id" => "event",
      "processed_at" => @time,
      "content" => "private",
      "unknown" => "private"
    }

    assert %NativeObservation{
             supported?: true,
             native_id: "event",
             occurred_at: time,
             safe_payload: safe
           } = Claude.interpret(payload)

    assert DateTime.to_iso8601(time) == @time
    assert safe == Map.take(payload, ["type", "id", "processed_at"])
    assert Claude.interpret(Map.put(payload, "processed_at", "broken")).malformed_metadata?
    refute Map.has_key?(safe, "attempt_id")
  end

  test "Bedrock interpretation recognizes Converse and trace without retaining bodies" do
    assert %NativeObservation{supported?: true, safe_payload: %{"contentBlockDelta" => %{}}} =
             Bedrock.interpret(%{"contentBlockDelta" => %{"delta" => %{"text" => "private"}}})

    assert %NativeObservation{supported?: true, safe_payload: safe} =
             Bedrock.interpret(%{
               "traceId" => "trace",
               "spanId" => "span",
               "attributes" => %{"secret" => "private"}
             })

    assert safe == %{"traceId" => "trace", "spanId" => "span"}
    assert Bedrock.interpret(%{"messageStop" => %{"stopReason" => 12}}).malformed_metadata?
    refute Bedrock.interpret(%{"type" => "agent.message"}).supported?
    refute Claude.interpret(%{"messageStop" => %{}}).supported?
  end

  test "unknown payload retain stays exact while standalone drop is conservative" do
    payload = %{"type" => "future.private", "content" => "private"}
    attrs = record(payload)

    assert {:ok, %Record{payload: ^payload, validation_issue?: true}} =
             Record.new(attrs, content: :retain)

    assert {:ok, %Record{payload: %{}}} = Record.new(attrs)
  end

  test "restored source kind selects interpretation independently of capture provider and recorder" do
    for {provider, kind, payload} <- [
          {:managed, :claude_thread, %{"messageStop" => %{"stopReason" => "end_turn"}}},
          {:agentcore, :agentcore_stream, %{"type" => "agent.message", "id" => "event"}}
        ] do
      attrs = %{
        capture_id: "capture",
        provider: provider,
        session_id: "session",
        started_at: @time,
        ended_at: @time,
        sources: [%{id: "source", kind: kind, scope: "session", status: :complete}],
        records: [record(payload)]
      }

      assert {:ok, capture} = Capture.new(attrs)
      assert hd(capture.records).payload == %{}
      assert Enum.any?(capture.diagnostics, &(&1.code == :unsupported_record))
      assert {:ok, restored} = Capture.restore(ReqManagedAgents.Evidence.to_wire(capture))
      assert hd(restored.records).validation_issue?
    end
  end

  test "native facts constructor rejects untyped facts and non-JSON projections" do
    assert {:error, _} =
             NativeObservation.new(%{
               supported?: "true",
               malformed_metadata?: false,
               safe_payload: %{}
             })

    assert {:error, _} =
             NativeObservation.new(%{
               supported?: true,
               malformed_metadata?: false,
               safe_payload: %{"raw" => self()}
             })
  end

  test "restoration diagnoses mismatched retained dialect before default drop" do
    attrs = %{
      capture_id: "capture",
      provider: :managed,
      session_id: "session",
      started_at: @time,
      ended_at: @time,
      sources: [%{id: "source", kind: :claude_session, scope: "session", status: :complete}],
      records: [record(%{"messageStop" => %{"stopReason" => "end_turn"}, "secret" => "private"})]
    }

    assert {:ok, retained} = Capture.new(attrs, content: :retain)

    wire =
      retained
      |> ReqManagedAgents.Evidence.to_wire()
      |> Jason.encode!()
      |> Jason.decode!()

    assert {:ok, restored} = ReqManagedAgents.Evidence.from_wire(wire)
    assert hd(restored.records).payload == hd(attrs.records).payload
    assert hd(restored.records).validation_issue?
    assert {:ok, dropped} = Capture.new(restored)
    assert hd(dropped.records).payload == %{}
  end

  test "native facts reject raw payload fields and malformed Claude identities are diagnostic" do
    assert {:error, _} =
             NativeObservation.new(%{
               supported?: true,
               malformed_metadata?: false,
               safe_payload: %{},
               payload: %{"content" => "private"}
             })

    assert %NativeObservation{native_id: nil, malformed_metadata?: true} =
             Claude.interpret(%{"type" => "agent.message", "id" => ""})
  end

  test "recorder selects the session provider rather than a payload dialect" do
    alias ReqManagedAgents.Evidence.{Options, Recorder}
    {:ok, options} = Options.new([])

    for {provider, payload} <- [
          {:agentcore,
           %{"type" => "agent.message", "content" => "private", "processed_at" => @time}},
          {:managed, %{"messageStop" => %{"stopReason" => "end_turn"}}}
        ] do
      {:ok, recorder} = Recorder.start_link(options)
      Recorder.context(recorder, provider, "session")
      Recorder.native(recorder, payload)
      assert {:ok, capture} = Recorder.snapshot(recorder)
      assert [%Record{payload: %{}, occurred_at: nil, validation_issue?: true}] = capture.records
      assert Enum.any?(capture.diagnostics, &(&1.code == :unsupported_record))
      GenServer.stop(recorder)
    end
  end

  test "standalone records retain recognized trace metadata alongside an unknown type" do
    payload = %{
      "type" => "future",
      "traceId" => "trace",
      "spanId" => "span",
      "secret" => "private"
    }

    assert {:ok, %Record{payload: safe, validation_issue?: false}} = Record.new(record(payload))
    assert safe == %{"traceId" => "trace", "spanId" => "span"}
  end

  test "invalid native JSON is rejected without killing the recorder" do
    alias ReqManagedAgents.Evidence.{Options, Recorder}
    {:ok, options} = Options.new([])
    {:ok, recorder} = Recorder.start_link(options)
    Recorder.context(recorder, :managed, "session")
    Recorder.native(recorder, %{"type" => "agent.message", "name" => <<255>>})
    assert {:ok, capture} = Recorder.snapshot(recorder)
    assert capture.records == []
    assert Enum.any?(capture.diagnostics, &(&1.code == :capture_gap))
    assert Process.alive?(recorder)
    GenServer.stop(recorder)
  end

  test "capture rejects malformed record entries without raising during source selection" do
    attrs = %{
      capture_id: "capture",
      provider: :managed,
      session_id: "session",
      started_at: @time,
      ended_at: @time,
      sources: [%{id: "source", kind: :claude_session, scope: "session", status: :complete}],
      records: [nil]
    }

    assert {:error, _} = Capture.new(attrs)
  end

  defp record(payload) do
    %{
      id: "record",
      source_id: "source",
      ordinal: 1,
      observed_at: @time,
      clock: :wall,
      kind: :native,
      payload: payload
    }
  end
end
