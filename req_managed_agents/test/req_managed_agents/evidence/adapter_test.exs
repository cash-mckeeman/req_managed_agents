defmodule ReqManagedAgents.Evidence.AdapterTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Evidence
  alias ReqManagedAgents.Evidence.{Adapter, Capture, NativeObservation, Record}
  alias ReqManagedAgents.Providers.BedrockAgentCore.Evidence, as: Bedrock
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Event
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Evidence, as: Claude

  @time "2026-10-08T12:00:00Z"

  test "typed Claude idle reasons survive capture serialization without unsupported diagnostics" do
    for {reason, terminal} <- [
          {"end_turn", :end_turn},
          {"requires_action", :requires_action},
          {"future_reason", :unknown_idle}
        ] do
      payload = %{"type" => "session.status_idle", "stop_reason" => %{"type" => reason}}

      observation = Claude.interpret(payload)
      assert observation.supported?
      refute observation.malformed_metadata?
      assert observation.safe_payload == payload
      assert Event.classify(payload) == terminal
      assert {:ok, capture} = Capture.new(capture_attrs(payload))
      assert [%Record{payload: ^payload, validation_issue?: false}] = capture.records
      refute Enum.any?(capture.diagnostics, &(&1.code == :unsupported_record))

      wire = capture |> Evidence.to_wire() |> Jason.encode!() |> Jason.decode!()
      assert {:ok, restored} = Evidence.from_wire(wire)
      assert [%Record{payload: ^payload, validation_issue?: false}] = restored.records
      assert Event.classify(hd(restored.records).payload) == terminal
      refute Enum.any?(restored.diagnostics, &(&1.code == :unsupported_record))
    end
  end

  test "Claude stop reason projection excludes arbitrary nested content from capture JSON" do
    payload = %{
      "type" => "session.status_idle",
      "stop_reason" => %{
        "type" => "requires_action",
        "event_ids" => ["event"],
        "content" => "PRIVATE_SENTINEL",
        "extra" => %{"nested" => [%{"text" => "PRIVATE_SENTINEL"}]}
      }
    }

    safe = %{"type" => "session.status_idle", "stop_reason" => %{"type" => "requires_action"}}
    assert Claude.interpret(payload).safe_payload == safe
    assert {:ok, capture} = Capture.new(capture_attrs(payload))
    assert hd(capture.records).payload == safe
    encoded = Jason.encode!(Evidence.to_wire(capture))
    refute encoded =~ "PRIVATE_SENTINEL"
    assert {:ok, restored} = Evidence.from_wire(Jason.decode!(encoded))
    assert hd(restored.records).payload == safe
    refute Jason.encode!(Evidence.to_wire(restored)) =~ "PRIVATE_SENTINEL"

    assert {:ok, retained} = Capture.new(capture_attrs(payload), content: :retain)
    assert hd(retained.records).payload == payload
  end

  test "Claude stop reasons preserve legacy strings and optional absence" do
    for {fields, safe_fields} <- [
          {%{}, %{}},
          {%{"stop_reason" => nil}, %{}},
          {%{"stop_reason" => "end_turn"}, %{"stop_reason" => "end_turn"}},
          {%{"stop_reason" => ""}, %{"stop_reason" => ""}}
        ] do
      payload = Map.put(fields, "type", "session.status_idle")
      safe = Map.put(safe_fields, "type", "session.status_idle")
      refute Claude.interpret(payload).malformed_metadata?
      assert {:ok, capture} = Capture.new(capture_attrs(payload))
      assert [%Record{payload: ^safe, validation_issue?: false}] = capture.records
      refute Enum.any?(capture.diagnostics, &(&1.code == :unsupported_record))
    end
  end

  test "malformed Claude stop reasons remain diagnostic after content drop and JSON restoration" do
    for reason <- [
          %{},
          %{"type" => nil},
          %{"type" => ""},
          %{"type" => 1},
          %{"type" => true},
          %{"type" => []},
          %{"type" => %{"content" => "PRIVATE_SENTINEL"}},
          1,
          true,
          [],
          ["end_turn"]
        ] do
      payload = %{"type" => "session.status_idle", "stop_reason" => reason}
      observation = Claude.interpret(payload)
      assert observation.supported?
      assert observation.malformed_metadata?
      refute Map.has_key?(observation.safe_payload, "stop_reason")
      assert {:ok, capture} = Capture.new(capture_attrs(payload))
      assert [%Record{validation_issue?: true}] = capture.records
      assert Enum.any?(capture.diagnostics, &(&1.code == :unsupported_record))
      encoded = Jason.encode!(Evidence.to_wire(capture))
      refute encoded =~ "PRIVATE_SENTINEL"
      assert {:ok, restored} = Evidence.from_wire(Jason.decode!(encoded))
      assert Enum.any?(restored.diagnostics, &(&1.code == :unsupported_record))
      refute Map.has_key?(hd(restored.records).payload, "stop_reason")
    end
  end

  test "typed Claude stop reasons do not bypass native JSON validation" do
    for reason <- [
          %{"type" => <<255>>},
          %{"type" => "end_turn", "extra" => self()},
          %{"type" => "end_turn", :extra => "content"}
        ] do
      payload = %{"type" => "session.status_idle", "stop_reason" => reason}

      assert %NativeObservation{
               supported?: false,
               malformed_metadata?: true,
               safe_payload: %{}
             } = Claude.interpret(payload)

      assert {:error, _} = Capture.new(capture_attrs(payload))
    end
  end

  test "descriptor metadata excludes nested content" do
    payload = %{
      "type" => "session_thread",
      "id" => "sthr_child",
      "session_id" => "sesn_test",
      "parent_thread_id" => "sthr_parent",
      "agent" => %{"system" => "PRIVATE_SENTINEL"},
      "name" => "PRIVATE_SENTINEL",
      "system" => "PRIVATE_SENTINEL"
    }

    observation = Claude.interpret(payload)
    assert observation.supported?
    refute observation.malformed_metadata?
    assert observation.safe_payload == Map.take(payload, ~w(type id session_id parent_thread_id))
    assert {:ok, dropped} = Record.new(record(payload))
    assert dropped.payload == observation.safe_payload
    refute Jason.encode!(dropped.payload) =~ "PRIVATE_SENTINEL"
    assert {:ok, retained} = Record.new(record(payload), content: :retain)
    assert retained.payload == payload

    root = Map.put(payload, "parent_thread_id", nil)
    refute Claude.interpret(root).malformed_metadata?
    assert Map.fetch!(Claude.interpret(root).safe_payload, "parent_thread_id") == nil

    for {invalid, omitted} <- [
          {Map.delete(payload, "parent_thread_id"), "parent_thread_id"},
          {Map.put(payload, "parent_thread_id", 12), "parent_thread_id"},
          {Map.put(payload, "parent_thread_id", ""), "parent_thread_id"},
          {Map.put(payload, "session_id", nil), "session_id"},
          {Map.put(payload, "id", ""), "id"}
        ] do
      observation = Claude.interpret(invalid)
      assert observation.malformed_metadata?
      refute Map.has_key?(observation.safe_payload, omitted)
      assert {:ok, diagnosed} = Record.new(record(invalid))
      assert diagnosed.validation_issue?
      refute Map.has_key?(diagnosed.payload, omitted)
    end

    refute Claude.interpret(%{"type" => "unrelated", "id" => "other"}).supported?
  end

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

  test "Bedrock drop projection preserves cache metadata without content" do
    payload = %{
      "metadata" => %{
        "usage" => %{
          "inputTokens" => 12,
          "outputTokens" => 4,
          "cacheReadInputTokens" => 3,
          "cacheWriteInputTokens" => 2
        }
      },
      "contentBlockDelta" => %{"delta" => %{"text" => "PRIVATE_SENTINEL"}}
    }

    observation = Bedrock.interpret(payload)
    assert observation.supported?
    refute observation.malformed_metadata?
    assert get_in(observation.safe_payload, ["metadata", "usage", "cacheReadInputTokens"]) == 3
    assert get_in(observation.safe_payload, ["metadata", "usage", "cacheWriteInputTokens"]) == 2
    refute Jason.encode!(observation.safe_payload) =~ "PRIVATE_SENTINEL"
    malformed = put_in(payload, ["metadata", "usage", "cacheReadInputTokens"], "3")
    assert Bedrock.interpret(malformed).malformed_metadata?
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

  test "standalone CloudWatch envelopes survive default drop and declared capture composition" do
    payload = %{
      "eventId" => "event",
      "logStreamName" => "stream",
      "timestamp" => 1_791_460_800_000,
      "ingestionTime" => 1_791_460_801_000,
      "message" => "private",
      "unknown" => "private"
    }

    assert {:ok, %Record{validation_issue?: false, payload: ^payload, content_state: :retained}} =
             Record.new(record(payload), content: :retain)

    assert {:ok, %Record{validation_issue?: false, content_state: :dropped} = typed} =
             Record.new(record(payload))

    assert typed.payload == %{
             "eventId" => "event",
             "logStreamName" => "stream",
             "timestamp" => 1_791_460_800_000,
             "ingestionTime" => 1_791_460_801_000
           }

    assert {:ok, capture} =
             Capture.new(%{
               capture_id: "capture",
               provider: :agentcore,
               session_id: "session",
               started_at: @time,
               ended_at: @time,
               sources: [%{id: "source", kind: :cloudwatch, scope: "session", status: :complete}],
               records: [typed]
             })

    assert {:ok, with_type} = Record.new(record(Map.put(payload, "type", "future")))
    assert with_type.payload == typed.payload
    refute with_type.validation_issue?

    assert hd(capture.records).payload == typed.payload
    refute Enum.any?(capture.diagnostics, &(&1.code == :unsupported_record))

    wire =
      capture
      |> ReqManagedAgents.Evidence.to_wire()
      |> Jason.encode!()
      |> Jason.decode!()

    assert {:ok, restored} = ReqManagedAgents.Evidence.from_wire(wire)
    assert hd(restored.records).payload == typed.payload
    refute hd(restored.records).validation_issue?
    refute Enum.any?(restored.diagnostics, &(&1.code == :unsupported_record))

    for selector <- [:managed, :claude_session, :agentcore, :agentcore_stream] do
      refute Adapter.interpret(payload, selector).supported?
      assert Adapter.interpret(payload, selector).safe_payload == %{}
    end

    malformed = Map.put(payload, "timestamp", "broken")
    assert {:ok, %Record{validation_issue?: true, payload: safe}} = Record.new(record(malformed))
    refute Map.has_key?(safe, "timestamp")
    refute Map.has_key?(safe, "message")
  end

  test "standalone dispatch preserves provider precedence and drops arbitrary maps" do
    envelope = %{"eventId" => "event", "timestamp" => 10, "message" => "private"}

    claude = Map.merge(envelope, %{"type" => "agent.message", "id" => "claude"})

    assert Adapter.interpret(claude).safe_payload == %{
             "type" => "agent.message",
             "id" => "claude"
           }

    bedrock = Map.put(envelope, "messageStop", %{"stopReason" => "end_turn"})

    assert Adapter.interpret(bedrock).safe_payload == %{
             "messageStop" => %{"stopReason" => "end_turn"}
           }

    for payload <- [%{"private" => "secret"}, %{"type" => "future", "message" => "secret"}] do
      assert %NativeObservation{supported?: false, safe_payload: %{}} = Adapter.interpret(payload)
      assert {:ok, %Record{validation_issue?: true, payload: %{}}} = Record.new(record(payload))
    end
  end

  defp capture_attrs(payload) do
    %{
      capture_id: "capture",
      provider: :managed,
      session_id: "session",
      started_at: @time,
      ended_at: @time,
      sources: [%{id: "source", kind: :claude_session, scope: "session", status: :complete}],
      records: [record(payload)]
    }
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
