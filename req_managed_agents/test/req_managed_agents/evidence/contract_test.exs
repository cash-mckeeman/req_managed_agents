defmodule ReqManagedAgents.Evidence.ContractTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Evidence

  alias ReqManagedAgents.Evidence.{
    Capture,
    Correlation,
    Diagnostic,
    Error,
    Options,
    Record,
    Source
  }

  @time "2026-10-08T12:00:00Z"

  defp source(id \\ "session") do
    %{
      id: id,
      kind: :claude_session,
      scope: "native-session",
      status: :complete,
      pages: 1,
      records_seen: 1
    }
  end

  defp record(overrides \\ %{}) do
    Map.merge(
      %{
        id: "record-1",
        source_id: "session",
        native_id: "native-1",
        ordinal: 1,
        observed_at: @time,
        clock: :wall,
        kind: :native,
        payload: %{
          "type" => "agent.message",
          "id" => "native-1",
          "content" => [%{"type" => "text", "text" => "private text"}]
        }
      },
      overrides
    )
  end

  defp capture(overrides \\ %{}) do
    Map.merge(
      %{
        capture_id: "capture-1",
        provider: :managed,
        session_id: "native-session",
        started_at: @time,
        ended_at: @time,
        sources: [source()],
        records: [record()]
      },
      overrides
    )
  end

  test "version and closed discriminants reject unsupported input without echoing it" do
    for attrs <- [
          capture(%{version: 2}),
          capture(%{provider: "secret-provider"}),
          capture(%{records: [record(%{clock: :unknown})]})
        ] do
      assert {:error, %Error{}} = Capture.new(attrs)
    end

    assert {:error, error} = Source.new(%{source() | kind: "credential-value"})
    refute inspect(error) =~ "credential-value"
    assert {:error, %Error{}} = Diagnostic.new(%{code: :unknown})
  end

  test "required identity, collection bounds and source ordinals fail at ingress" do
    for attrs <- [
          capture(%{capture_id: ""}),
          capture(%{ended_at: "2026-10-07T12:00:00Z"}),
          capture(%{sources: [source(), source()]}),
          capture(%{records: [record(%{source_id: "missing"})]}),
          capture(%{records: [record(%{ordinal: 0})]}),
          capture(%{records: [record(), record(%{id: "r2"})]}),
          capture(%{session_id: nil})
        ] do
      assert {:error, %Error{}} = Capture.new(attrs)
    end

    assert {:error, %Error{}} =
             Source.new(Map.put(source(), :interval, %{from: @time, to: "2026-10-07T12:00:00Z"}))
  end

  test "retained producer JSON roundtrips identity, source coverage and native payload" do
    assert {:ok, built} = Capture.new(capture(), content: :retain)
    wire = built |> Evidence.to_wire() |> Jason.encode!() |> Jason.decode!()
    assert wire["version"] == 1
    assert wire["records"] |> hd() |> Map.fetch!("native_id") == "native-1"
    assert {:ok, restored} = Evidence.from_wire(wire)
    assert hd(restored.records).payload == record().payload
    assert hd(restored.sources).status == :complete
    assert hd(restored.sources).scope == "native-session"
    assert hd(restored.records).content_state == :retained
    assert {:error, %Error{}} = Evidence.from_wire(Map.put(wire, "version", 2))
  end

  test "default drop removes arbitrary content and malformed allowlisted metadata" do
    payload = %{
      "type" => "agent.custom_tool_use",
      "id" => "native-1",
      "name" => "lookup",
      "input" => %{"token" => "secret"},
      "content" => "secret",
      "thinking" => "secret",
      "attributes" => %{"token" => "secret"},
      "unknown" => "secret",
      "usage" => %{"input_tokens" => 7, "output_tokens" => "secret", "extra" => "secret"},
      "status" => %{"value" => "secret"}
    }

    assert {:ok, built} = Capture.new(capture(%{records: [record(%{payload: payload})]}))

    assert hd(built.records).payload == %{
             "type" => "agent.custom_tool_use",
             "id" => "native-1",
             "name" => "lookup",
             "usage" => %{"input_tokens" => 7}
           }

    assert hd(built.records).content_state == :dropped
    refute Jason.encode!(Evidence.to_wire(built)) =~ "secret"
    assert Enum.any?(built.diagnostics, &(&1.code == :content_unavailable))
  end

  test "unknown native shapes survive retain and produce counted safe diagnostics on drop" do
    attrs = capture(%{records: [record(%{payload: %{"alien" => "secret"}})]})
    assert {:ok, dropped} = Capture.new(attrs)
    assert hd(dropped.records).payload == %{}
    assert Enum.any?(dropped.diagnostics, &(&1.code == :unsupported_record and &1.count == 1))
    assert {:ok, retained} = Capture.new(attrs, content: :retain)
    assert hd(retained.records).payload == %{"alien" => "secret"}
  end

  test "native IDs are scoped to source and conflicting duplicates remain distinct" do
    records = [
      record(),
      record(%{id: "r2", source_id: "thread"}),
      record(%{id: "r3", ordinal: 2, payload: %{"type" => "agent.message", "content" => "other"}})
    ]

    assert {:ok, built} =
             Capture.new(capture(%{sources: [source(), source("thread")], records: records}),
               content: :retain
             )

    assert length(built.records) == 3
    assert Enum.any?(built.diagnostics, &(&1.code == :conflicting_duplicate))
  end

  test "optional malformed native timestamps degrade with diagnostics" do
    assert {:ok, built} = Capture.new(capture(%{records: [record(%{occurred_at: "secret"})]}))
    assert hd(built.records).occurred_at == nil
    assert Enum.any?(built.diagnostics, &(&1.code == :unsupported_record))
    refute Jason.encode!(Evidence.to_wire(built)) =~ "secret"
  end

  test "correlations reject dangling record references and unsafe origin values" do
    link = %{
      from_record_id: "record-1",
      relation: :parent,
      target: %{namespace: :record, id: "missing"},
      evidence_record_ids: ["record-1"]
    }

    assert {:error, %Error{}} = Capture.new(capture(%{correlations: [link]}))

    assert {:error, %Error{}} =
             Capture.new(
               capture(%{
                 correlations: [
                   %{
                     link
                     | target: %{namespace: :record, id: "record-1"},
                       evidence_record_ids: ["missing"]
                   }
                 ]
               })
             )

    for bad <- ["/private/session", "https://example.test/session", "Bearer secret"] do
      assert {:error, %Error{}} =
               Correlation.new(%{
                 link
                 | relation: :origin,
                   target: %{namespace: :origin, harness: :codex, session_id: bad}
               })
    end

    assert {:error, %Error{}} =
             Correlation.new(%{
               link
               | relation: :origin,
                 target: %{
                   namespace: :origin,
                   harness: :codex,
                   session_id: "native",
                   path: "/private"
                 }
             })
  end

  test "diagnostic and error messages are generated from codes" do
    assert {:ok, diagnostic} = Diagnostic.new(%{code: :capture_gap, message: "Bearer secret"})
    refute diagnostic.message =~ "secret"
    assert {:ok, error} = Error.new(%{code: :invalid_input, message: "Bearer secret"})
    refute error.message =~ "secret"
  end

  test "options and aggregate capture bounds cannot silently declare completeness" do
    for opts <- [
          [max_pages: 0],
          [max_records: -1],
          [max_bytes: 0],
          [timeout_ms: "secret"],
          [content: :unknown],
          [unexpected: true]
        ] do
      assert {:error, %Error{}} = Options.new(opts)
    end

    assert {:ok, built} =
             Capture.new(
               capture(%{
                 records: [record(), record(%{id: "r2", ordinal: 2, native_id: "native-2"})]
               }),
               max_records: 1
             )

    assert length(built.records) == 1
    assert hd(built.sources).status == :partial
    assert Enum.any?(built.diagnostics, &(&1.code == :bound_exceeded and &1.count == 1))
    assert {:error, %Error{}} = Capture.new(capture(), max_bytes: 1)
  end

  test "local payloads validate lifecycle and scoped monotonic time without serializing exceptions" do
    local =
      record(%{
        kind: :local,
        native_id: nil,
        invocation_id: "inv-1",
        attempt_id: "attempt-1",
        clock: :monotonic,
        clock_id: "recorder-1",
        monotonic_ticks: 10,
        payload: %{type: :attempt_started, invocation_id: "inv-1", attempt_id: "attempt-1"}
      })

    assert {:ok, value} = Record.new(local)
    assert value.clock_id == "recorder-1"
    assert {:error, %Error{}} = Record.new(%{local | clock_id: nil})
    assert {:error, %Error{}} = Record.new(%{local | payload: %{type: :unknown}})

    assert {:error, %Error{}} =
             Record.new(%{
               local
               | payload: %{
                   type: :attempt_finished,
                   invocation_id: "inv-1",
                   attempt_id: "attempt-1",
                   error: %{token: "secret"}
                 }
             })
  end

  test "drop preserves native model usage and explicit link metadata" do
    payload = %{
      "type" => "span.model_request_end",
      "model_request_start_id" => "start-1",
      "model_usage" => %{"input_tokens" => 12, "output_tokens" => 4, "secret" => "hidden"},
      "processed_at" => @time,
      "session_thread_id" => "thread-1",
      "custom_tool_use_id" => "tool-1"
    }

    assert {:ok, built} = Capture.new(capture(%{records: [record(%{payload: payload})]}))
    actual = hd(built.records).payload
    assert actual["model_usage"] == %{"input_tokens" => 12, "output_tokens" => 4}
    assert actual["model_request_start_id"] == "start-1"
    assert actual["session_thread_id"] == "thread-1"
    assert actual["custom_tool_use_id"] == "tool-1"
    assert actual["processed_at"] == @time
  end

  test "exact native duplicates coalesce while explicit references stay resolvable" do
    link = %{
      from_record_id: "r2",
      relation: :same_session,
      target: %{namespace: :session, id: "native-session"},
      evidence_record_ids: ["r2"]
    }

    assert {:ok, built} =
             Capture.new(
               capture(%{
                 records: [record(), record(%{id: "r2", ordinal: 2})],
                 correlations: [link]
               }),
               content: :retain
             )

    assert Enum.map(built.records, & &1.id) == ["record-1"]
    assert hd(built.correlations).from_record_id == "record-1"
    assert hd(built.correlations).evidence_record_ids == ["record-1"]
    refute Enum.any?(built.diagnostics, &(&1.code == :conflicting_duplicate))
  end

  test "byte bounds drop evidence with counted gaps and remove orphaned correlations" do
    records =
      for n <- 1..3,
          do:
            record(%{
              id: "r#{n}",
              native_id: "n#{n}",
              ordinal: n,
              payload: %{"type" => "agent.message", "content" => String.duplicate("x", 3000)}
            })

    link = %{
      from_record_id: "r3",
      relation: :same_session,
      target: %{namespace: :session, id: "native-session"},
      evidence_record_ids: ["r3"]
    }

    assert {:ok, built} =
             Capture.new(capture(%{records: records, correlations: [link]}),
               content: :retain,
               max_bytes: 6000
             )

    assert length(built.records) == 1
    assert built.correlations == []
    assert byte_size(Jason.encode!(Evidence.to_wire(built))) <= 6000
    assert Enum.any?(built.diagnostics, &(&1.code == :bound_exceeded and &1.count == 2))
    assert Enum.any?(built.diagnostics, &(&1.code == :invalid_correlation))
  end

  test "wire ingress requires explicit record content state" do
    assert {:ok, built} = Capture.new(capture(), content: :retain)
    wire = Evidence.to_wire(built)
    bad = update_in(wire["records"], &Enum.map(&1, fn r -> Map.delete(r, "content_state") end))
    assert {:error, %Error{}} = Evidence.from_wire(bad)
  end

  test "AgentCore stream metadata survives drop without tool input or generated text" do
    payloads = [
      %{
        "contentBlockStart" => %{
          "contentBlockIndex" => 0,
          "start" => %{
            "toolUse" => %{"toolUseId" => "tool-1", "name" => "lookup", "input" => "secret"}
          }
        }
      },
      %{"contentBlockDelta" => %{"contentBlockIndex" => 0, "delta" => %{"text" => "secret"}}},
      %{
        "metadata" => %{
          "usage" => %{"inputTokens" => 3, "outputTokens" => 4},
          "secret" => "secret"
        }
      }
    ]

    records =
      Enum.with_index(payloads, 1)
      |> Enum.map(fn {p, n} ->
        record(%{id: "r#{n}", native_id: nil, ordinal: n, payload: p})
      end)

    assert {:ok, built} =
             Capture.new(
               capture(%{
                 provider: :agentcore,
                 records: records,
                 sources: [%{source() | kind: :agentcore_stream}]
               })
             )

    [start, delta, usage] = built.records

    assert start.payload["contentBlockStart"]["start"]["toolUse"] == %{
             "toolUseId" => "tool-1",
             "name" => "lookup"
           }

    assert delta.payload == %{"contentBlockDelta" => %{"contentBlockIndex" => 0}}

    assert usage.payload == %{
             "metadata" => %{"usage" => %{"inputTokens" => 3, "outputTokens" => 4}}
           }

    refute Jason.encode!(Evidence.to_wire(built)) =~ "secret"
  end

  test "dropped conflicting records stay distinct after serialization and artifact revalidation" do
    assert {:ok, built} =
             Capture.new(
               capture(%{
                 records: [
                   record(),
                   record(%{
                     id: "r2",
                     ordinal: 2,
                     payload: %{
                       "type" => "agent.message",
                       "id" => "native-1",
                       "content" => "different"
                     }
                   })
                 ]
               })
             )

    assert length(built.records) == 2
    assert {:ok, restored} = built |> Evidence.to_wire() |> Evidence.from_wire()
    assert Enum.map(restored.records, & &1.id) == ["record-1", "r2"]
    assert Enum.any?(restored.diagnostics, &(&1.code == :conflicting_duplicate))
  end

  test "source and capture bounds reject mismatched local/native sources and collection times" do
    assert {:error, %Error{}} =
             Capture.new(capture(%{records: [record(%{observed_at: "2026-10-08T12:00:01Z"})]}))

    assert {:error, %Error{}} = Capture.new(capture(%{sources: [%{source() | kind: :rma_local}]}))
    assert {:error, %Error{}} = Capture.new(capture(%{provider: :agentcore}))
  end

  test "reading an existing capture preserves declared coverage beyond default collection limits" do
    sources = [%{source() | pages: 101}]

    assert {:ok, built} =
             Capture.new(capture(%{sources: sources}), max_pages: 102, content: :retain)

    assert {:ok, restored} = built |> Evidence.to_wire() |> Evidence.from_wire()
    assert hd(restored.sources).status == :complete
    assert restored.diagnostics == []
  end

  test "malformed optional native metadata is diagnosed while retained raw evidence survives" do
    payload = %{
      "type" => "span.model_request_end",
      "processed_at" => "not-a-time",
      "model_usage" => %{"input_tokens" => "not-a-number"}
    }

    assert {:ok, built} =
             Capture.new(capture(%{records: [record(%{payload: payload})]}), content: :retain)

    assert hd(built.records).payload == payload
    assert Enum.any?(built.diagnostics, &(&1.code == :unsupported_record))
  end

  test "page bounds label unknown missing evidence as a gap" do
    assert {:ok, built} = Capture.new(capture(%{sources: [%{source() | pages: 2}]}), max_pages: 1)
    assert hd(built.sources).status == :partial
    assert Enum.any?(built.diagnostics, &(&1.code == :capture_gap and &1.count == 0))
  end

  test "a pre-open local failure can lack a native session without inventing one" do
    local =
      record(%{
        kind: :local,
        native_id: nil,
        invocation_id: "inv-1",
        attempt_id: "attempt-1",
        payload: %{
          type: :transport_failed,
          invocation_id: "inv-1",
          attempt_id: "attempt-1",
          error_code: "connection_refused",
          result: :error
        }
      })

    assert {:ok, built} =
             Capture.new(
               capture(%{
                 session_id: nil,
                 records: [local],
                 sources: [%{source() | kind: :rma_local}]
               })
             )

    assert built.session_id == nil
    assert hd(built.records).native_id == nil
  end

  test "byte truncation cannot erase the only evidence establishing a sessionless failure" do
    invocation_id = String.duplicate("i", 1024)

    local =
      record(%{
        kind: :local,
        native_id: nil,
        invocation_id: invocation_id,
        attempt_id: "a",
        payload: %{
          type: :transport_failed,
          invocation_id: invocation_id,
          attempt_id: "a",
          error_code: "connection_refused",
          result: :error
        }
      })

    assert {:error, %Error{code: :bound_exceeded}} =
             Capture.new(
               capture(%{
                 session_id: nil,
                 records: [local],
                 sources: [%{source() | kind: :rma_local}]
               }),
               max_bytes: 1500
             )
  end

  test "malformed AgentCore metadata is diagnosed under both content policies" do
    fixtures = [
      {:agentcore_stream,
       %{"metadata" => %{"usage" => %{"inputTokens" => "rejected-secret", "outputTokens" => 4}}},
       %{"metadata" => %{"usage" => %{"outputTokens" => 4}}}},
      {:agentcore_stream, %{"messageStart" => %{"role" => %{"value" => "rejected-secret"}}},
       %{"messageStart" => %{}}},
      {:agentcore_stream, %{"messageStop" => %{"stopReason" => ["rejected-secret"]}},
       %{"messageStop" => %{}}},
      {:agentcore_stream,
       %{
         "contentBlockStart" => %{
           "contentBlockIndex" => "rejected-secret",
           "start" => %{"toolUse" => %{"toolUseId" => "tool-1", "name" => ["rejected-secret"]}}
         }
       }, %{"contentBlockStart" => %{"start" => %{"toolUse" => %{"toolUseId" => "tool-1"}}}}},
      {:agentcore_stream, %{"contentBlockDelta" => %{"contentBlockIndex" => "rejected-secret"}},
       %{"contentBlockDelta" => %{}}},
      {:agentcore_stream, %{"contentBlockStop" => %{"contentBlockIndex" => -1}},
       %{"contentBlockStop" => %{}}},
      {:cloudwatch,
       %{
         "traceId" => "trace-1",
         "spanId" => "span-1",
         "startTimeUnixNano" => "rejected-secret",
         "endTimeUnixNano" => -1,
         "parentSpanId" => ["rejected-secret"]
       }, %{"traceId" => "trace-1", "spanId" => "span-1"}}
    ]

    for {kind, payload, dropped_payload} <- fixtures, policy <- [:drop, :retain] do
      attrs =
        capture(%{
          provider: :agentcore,
          sources: [%{source() | kind: kind}],
          records: [record(%{payload: payload})]
        })

      assert {:ok, built} = Capture.new(attrs, content: policy)

      assert Enum.any?(
               built.diagnostics,
               &(&1.code == :unsupported_record and &1.record_id == "record-1")
             ),
             "missing diagnostic for #{inspect(kind)} #{inspect(payload)} under #{policy}"

      assert hd(built.records).payload ==
               if(policy == :retain, do: payload, else: dropped_payload)

      refute inspect(built.diagnostics) =~ "rejected-secret"
    end
  end

  test "typed records preserve optional-field diagnostics without preserving rejected input" do
    fixtures = [
      {:managed, :claude_session, %{occurred_at: "rejected-secret"}},
      {:managed, :claude_session,
       %{payload: %{"type" => "span.model_request_end", "processed_at" => "rejected-secret"}}},
      {:managed, :claude_session,
       %{
         payload: %{
           "type" => "span.model_request_end",
           "model_usage" => %{"input_tokens" => "rejected-secret", "output_tokens" => 4}
         }
       }},
      {:agentcore, :agentcore_stream,
       %{
         payload: %{
           "metadata" => %{"usage" => %{"inputTokens" => "rejected-secret", "outputTokens" => 4}}
         }
       }}
    ]

    for {provider, kind, overrides} <- fixtures, policy <- [:drop, :retain] do
      raw_record = record(overrides)
      assert {:ok, typed_record} = Record.new(raw_record, content: policy)
      assert typed_record.occurred_at == nil
      if policy == :drop, do: refute(inspect(typed_record) =~ "rejected-secret")
      assert {:ok, typed_record} = Record.new(typed_record, content: policy)

      assert {:ok, built} =
               Capture.new(
                 capture(%{
                   provider: provider,
                   sources: [%{source() | kind: kind}],
                   records: [typed_record]
                 }),
                 content: policy
               )

      assert Enum.count(
               built.diagnostics,
               &(&1.code == :unsupported_record and &1.record_id == "record-1")
             ) == 1

      refute inspect(built.diagnostics) =~ "rejected-secret"
      wire = Evidence.to_wire(built)

      assert Enum.sort(Map.keys(hd(wire["records"]))) ==
               ~w(attempt_id clock clock_id content_state id invocation_id kind monotonic_ticks native_id observed_at occurred_at ordinal payload source_id)

      assert {:ok, restored} = wire |> Jason.encode!() |> Jason.decode!() |> Evidence.from_wire()

      assert Enum.count(
               restored.diagnostics,
               &(&1.code == :unsupported_record and &1.record_id == "record-1")
             ) == 1

      if policy == :drop,
        do: refute(Jason.encode!(Evidence.to_wire(restored)) =~ "rejected-secret")
    end
  end
end
