defmodule ReqManagedAgents.CloudWatch.NativeLogsTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Acceptance.StoredEvidence
  alias ReqManagedAgents.CloudWatch.{Client, Query}
  alias ReqManagedAgents.CloudWatch.Evidence, as: CloudWatch
  alias ReqManagedAgents.Evidence
  alias ReqManagedAgents.Evidence.{Capture, Options}
  alias ReqManagedAgents.Providers.BedrockAgentCore.CloudWatchLogs

  test "flattened logs retain exact bytes and link only five supported same-session observations" do
    events = events()
    capture = enrich(events)
    assert Enum.map(capture.records, & &1.payload) == events
    assert Enum.map(capture.records, & &1.native_id) == Enum.map(events, & &1["eventId"])
    assert length(capture.correlations) == 5
    assert linked(capture) == Enum.map(1..5, &"example-event-#{&1}")
    assert [%{status: :partial, reason: :unsupported_record}] = capture.sources
    assert StoredEvidence.assess(capture.sources, capture.records).outcome == :inconclusive
    assert Enum.all?(capture.records, &(is_nil(&1.invocation_id) and is_nil(&1.attempt_id)))

    assert Enum.all?(capture.correlations, fn link ->
             link.relation == :same_session and link.target.namespace == :session and
               link.target.id == "example-session" and
               link.evidence_record_ids == [link.from_record_id]
           end)

    assert {:ok, restored} = capture |> Evidence.to_wire() |> Evidence.from_wire()
    assert Evidence.to_wire(restored) == Evidence.to_wire(capture)
    assert StoredEvidence.assess(restored.sources, restored.records).outcome == :inconclusive
  end

  test "supported records alone complete coverage without manufacturing spans" do
    capture = events() |> Enum.take(5) |> enrich()
    assert [%{status: :complete}] = capture.sources
    assert StoredEvidence.assess(capture.sources, capture.records).outcome == :passed
    assert length(capture.correlations) == 5
  end

  test "the default OTLP matcher does not opt into the provider log dialect" do
    capture = enrich(Enum.take(events(), 1), [], [])
    assert capture.correlations == []
    assert [%{status: :partial}] = capture.sources
  end

  test "missing or conflicting identities and malformed nanosecond times remain unlinked" do
    [event | _] = events()

    replacements = [
      %{"traceId" => ""},
      %{"traceId" => String.duplicate("0", 32)},
      %{"traceId" => String.duplicate("g", 32)},
      %{"spanId" => ""},
      %{"spanId" => String.duplicate("0", 16)},
      %{"spanId" => String.duplicate("g", 16)},
      %{"timeUnixNano" => "1767225600000000000"},
      %{"timeUnixNano" => -1},
      %{"timeUnixNano" => 18_446_744_073_709_551_616},
      %{
        "timeUnixNano" => 1_767_225_600_001_000_000,
        "observedTimeUnixNano" => 1_767_225_600_001_500_000
      },
      %{"observedTimeUnixNano" => -1},
      %{"observedTimeUnixNano" => 1_767_225_599_999_999_999},
      %{"observedTimeUnixNano" => 18_446_744_073_709_551_616},
      %{"attributes" => %{}},
      %{"attributes" => %{"sessionId" => "example-session"}},
      %{"resource" => []},
      %{"scope" => %{}},
      %{"severityNumber" => "INFO"},
      %{"flags" => "1"}
    ]

    message = Jason.decode!(event["message"])

    aliases =
      for {key, value} <- [
            {"sessionId", "foreign-session"},
            {"sessionId", nil},
            {"otelTraceID", String.duplicate("b", 32)},
            {"otelSpanID", String.duplicate("c", 16)},
            {"otelTraceID", nil},
            {"otelSpanID", nil}
          ] do
        %{"attributes" => Map.put(message["attributes"], key, value)}
      end

    malformed =
      Enum.map(replacements ++ aliases, fn fields ->
        %{event | "message" => Jason.encode!(Map.merge(message, fields))}
      end)

    malformed = malformed ++ [%{event | "timestamp" => -1}, %{event | "ingestionTime" => nil}]
    capture = enrich(malformed ++ [event])
    assert length(capture.records) == length(malformed) + 1
    assert length(capture.correlations) == 1
    assert List.last(capture.records).id == hd(capture.correlations).from_record_id
    assert [%{status: :partial}] = capture.sources
  end

  test "valid foreign-session metadata cannot link through body, request or stream hints" do
    [event | _] = events()
    message = Jason.decode!(event["message"])
    message = put_in(message, ["attributes", "sessionId"], "foreign-session")
    message = put_in(message, ["attributes", "requestId"], "example-session")
    message = %{message | "body" => "sessionId=example-session"}
    event = %{event | "logStreamName" => "example-session", "message" => Jason.encode!(message)}
    capture = enrich([event])
    assert capture.correlations == []
    assert [%{status: :partial}] = capture.sources
    assert hd(capture.records).payload == event
  end

  test "trace selection is case-insensitive and never broadens session membership" do
    [event | _] = events()

    for selected <- ["00000000000000000000000000000001", "0000000000000000000000000000000A"] do
      expected = if String.ends_with?(selected, "1"), do: 1, else: 0
      assert length(enrich([event], trace_ids: [selected]).correlations) == expected
    end

    message = Jason.decode!(event["message"])
    trace = String.duplicate("aB", 16)
    message = put_in(message, ["attributes", "otelTraceID"], String.downcase(trace))
    event = %{event | "message" => Jason.encode!(%{message | "traceId" => trace})}
    assert length(enrich([event], trace_ids: [String.upcase(trace)]).correlations) == 1
  end

  test "drop removes private content and preserves conflicting native event identities" do
    [event | _] = events()
    changed = %{event | "message" => event["message"] <> " "}
    capture = enrich([event, event, changed], [], [message_association: CloudWatchLogs], :drop)
    encoded = Jason.encode!(Evidence.to_wire(capture))
    refute encoded =~ "Synthetic private log message"
    refute encoded =~ "example_function"
    refute encoded =~ "sessionId"
    assert Enum.map(capture.records, & &1.native_id) == List.duplicate("example-event-1", 3)
    assert length(Enum.uniq_by(capture.records, & &1.id)) == 3
    assert Enum.any?(capture.diagnostics, &(&1.code == :conflicting_duplicate))
    assert {:ok, restored} = Evidence.from_wire(Jason.decode!(encoded))
    assert length(restored.records) == 3
  end

  test "unknown matcher modules are refused before acquisition" do
    owner = self()
    {:ok, options} = Options.new(content: :retain)

    for module <- [__MODULE__, "Elixir.UntrustedModule", nil, [:invalid]] do
      assert {:error, %Evidence.Error{code: :invalid_options}} =
               CloudWatch.enrich(prior(), query([]), options,
                 client: client([], fn -> send(owner, :unexpected_acquisition) end),
                 message_association: module
               )
    end

    refute_received :unexpected_acquisition
  end

  defp enrich(
         events,
         query_opts \\ [],
         matcher \\ [message_association: CloudWatchLogs],
         content \\ :retain
       ) do
    {:ok, options} = Options.new(content: content)

    assert {:ok, capture} =
             CloudWatch.enrich(
               prior(),
               query(query_opts),
               options,
               [client: client(events)] ++ matcher
             )

    capture
  end

  defp linked(capture) do
    ids = MapSet.new(capture.correlations, & &1.from_record_id)

    capture.records
    |> Enum.filter(&MapSet.member?(ids, &1.id))
    |> Enum.map(& &1.native_id)
  end

  defp events do
    "test/fixtures/agentcore/cloudwatch_logs.json"
    |> File.read!()
    |> Jason.decode!()
  end

  defp prior do
    {:ok, capture} =
      Capture.new(
        %{
          capture_id: "example-capture",
          provider: :agentcore,
          session_id: "example-session",
          started_at: ~U[2026-01-01 00:00:00Z],
          ended_at: ~U[2026-01-01 00:00:01Z],
          sources: [],
          records: []
        },
        content: :retain
      )

    capture
  end

  defp query(opts) do
    {:ok, query} =
      Query.new(
        Map.merge(
          %{
            region: "us-east-1",
            log_group: "/example/runtime",
            session_id: "example-session",
            from: ~U[2026-01-01 00:00:00Z],
            to: ~U[2026-01-01 00:01:00Z]
          },
          Map.new(opts)
        )
      )

    query
  end

  defp client(events, before_response \\ fn -> :ok end) do
    {:ok, client} =
      Client.new(
        region: "us-east-1",
        credentials: %{access_key_id: "synthetic-key", secret_access_key: "synthetic-secret"},
        transport: fn conn ->
          before_response.()
          Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"events" => events}))
        end
      )

    client
  end
end
