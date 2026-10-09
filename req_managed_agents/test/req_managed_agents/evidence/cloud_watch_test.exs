defmodule ReqManagedAgents.Evidence.CloudWatchTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Evidence
  alias ReqManagedAgents.Evidence.{Capture, CloudWatch, CloudWatchClient, Options}
  alias ReqManagedAgents.Evidence.CloudWatch.Query

  test "signed JSON requests continue an empty intermediate page and preserve invocation evidence" do
    original = prior()
    owner = self()

    client =
      client(fn conn, request ->
        send(owner, {:request, request})
        assert conn.method == "POST"
        assert conn.host == "logs.us-east-1.amazonaws.com"
        assert conn.request_path == "/"
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/x-amz-json-1.1"]
        assert Plug.Conn.get_req_header(conn, "x-amz-target") == ["Logs_20140328.FilterLogEvents"]
        [authorization] = Plug.Conn.get_req_header(conn, "authorization")
        assert authorization =~ "/us-east-1/logs/aws4_request"
        assert Plug.Conn.get_req_header(conn, "x-amz-security-token") == ["synthetic-token"]
        assert request["logGroupName"] == "/example/agent"
        assert request["startTime"] == 1_767_225_600_000
        assert request["endTime"] == 1_767_225_660_000
        assert request["unmask"] == false

        case request["nextToken"] do
          nil -> page([event("first")], "empty")
          "empty" -> page([], "last")
          "last" -> page([event("last")])
        end
      end)

    capture = enrich(original, client)
    assert Enum.take(capture.records, 1) == original.records
    assert capture.capture_id == original.capture_id
    assert Enum.map(tl(capture.records), & &1.native_id) == ["first", "last"]
    assert List.last(capture.sources).scope == "us-east-1:/example/agent"
    assert List.last(capture.sources).pages == 3
    assert List.last(capture.sources).status == :complete
    assert List.last(capture.sources).interval.from == ~U[2026-01-01 00:00:00Z]
    assert List.last(capture.records).payload == event("last")
    assert Enum.all?(tl(capture.records), &(&1.invocation_id == nil and &1.attempt_id == nil))
    assert Enum.map(capture.correlations, & &1.relation) == [:same_session, :same_session]
    assert {:ok, _} = capture |> Evidence.to_wire() |> Evidence.from_wire()
    assert_received {:request, %{"nextToken" => "last"}}
  end

  test "cycles, malformed pages and denied requests preserve preceding evidence" do
    for {response, reason, status} <- [
          {page([], "again"), :cursor_cycle, :partial},
          {%{"events" => "bad"}, :incomplete_retrieval, :partial},
          {%{"events" => [], "nextToken" => 4}, :incomplete_retrieval, :partial},
          {{403, %{"__type" => "AccessDeniedException", "message" => "private-error"}},
           :source_unavailable, :partial}
        ] do
      capture =
        enrich(
          prior(),
          client(fn _, request ->
            if request["nextToken"], do: response, else: page([event("before")], "again")
          end)
        )

      assert Enum.map(capture.records, & &1.native_id) == [nil, "before"]
      assert List.last(capture.sources).reason == reason
      assert List.last(capture.sources).status == status
      refute Jason.encode!(Evidence.to_wire(capture)) =~ "private-error"
    end

    denied = enrich(prior(), client(fn _, _ -> {403, %{}} end))
    assert denied.records == prior().records
    assert List.last(denied.sources).status == :unavailable
  end

  test "query rejects destination injection, invalid intervals and malformed trace identifiers" do
    for replacement <- [
          %{region: "us-east-1/other"},
          %{log_group: ""},
          %{log_group: ["a", "b"]},
          %{from: ~U[2026-01-02 00:00:00Z]},
          %{to: "bad"},
          %{session_id: ""},
          %{trace_ids: ["not-a-trace"]},
          %{credentials: %{secret: "private"}}
        ] do
      assert {:error, %Evidence.Error{}} = Query.new(Map.merge(query_attrs(), replacement))
    end

    {:ok, options} = Options.new([])

    assert {:error, _} =
             CloudWatch.enrich(%{prior() | session_id: "other"}, query(), options,
               client: client(fn _, _ -> flunk("called") end)
             )
  end

  test "schema-gated session membership never invents parentage or native durations" do
    valid = event("valid")

    reversed =
      event("reversed", span(%{"startTimeUnixNano" => "200", "endTimeUnixNano" => "100"}))

    unrelated = event("unrelated", span(%{"attributes" => session("other")}))
    malformed = %{event("malformed") | "message" => "not-json private-message"}

    impostor =
      event("impostor", %{"traceId" => "x", "spanId" => "y", "attributes" => session("s")})

    capture =
      enrich(
        prior(),
        client(fn _, _ -> page([valid, reversed, unrelated, malformed, impostor]) end)
      )

    assert length(capture.records) == 6
    linked = Enum.map(capture.correlations, & &1.from_record_id)
    assert linked == [Enum.at(capture.records, 1).id]

    assert Enum.all?(
             capture.correlations,
             &(&1.relation == :same_session and &1.target.namespace == :session and
                 &1.target.id == "s")
           )

    assert Enum.count(capture.diagnostics, &(&1.code == :unsupported_record)) >= 4
    assert Enum.at(capture.records, 2).payload == reversed
    assert List.last(capture.sources).status == :partial
    {:ok, traced} = Query.new(Map.put(query_attrs(), :trace_ids, [String.duplicate("b", 32)]))
    filtered = enrich(prior(), client(fn _, _ -> page([valid]) end), [], traced)
    assert filtered.correlations == []
  end

  test "empty completed query reports only its interval and a later query can admit delayed telemetry" do
    empty = enrich(prior(), client(fn _, _ -> page([]) end))
    assert empty.records == prior().records
    assert List.last(empty.sources).status == :complete
    later = enrich(empty, client(fn _, _ -> page([event("delayed")]) end))
    assert Enum.map(later.records, & &1.native_id) == [nil, "delayed"]
    assert length(later.sources) == 3
  end

  test "aggregate pages and inspected records include prior sources and malformed records" do
    for {opts, response, expected} <- [
          {[max_pages: 1], page([event("never")]), [nil]},
          {[max_records: 3], page([false, event("last"), event("never")]), [nil, "last"]}
        ] do
      capture = enrich(prior(), client(fn _, _ -> response end), opts)
      assert Enum.map(capture.records, & &1.native_id) == expected
      assert Enum.any?(capture.diagnostics, &(&1.code == :bound_exceeded))
    end
  end

  test "retained byte bounds and deadline preserve the original capture" do
    huge = %{event("huge") | "message" => String.duplicate("private", 5_000)}
    capture = enrich(prior(), client(fn _, _ -> page([huge]) end), max_bytes: 4_000)
    assert capture.records == prior().records
    assert byte_size(Jason.encode!(Evidence.to_wire(capture))) <= 4_000
    owner = self()

    timed =
      enrich(
        prior(),
        client(fn _, _ ->
          send(owner, {:worker, self()})
          Process.sleep(5_000)
          page([])
        end),
        timeout_ms: 100
      )

    assert timed.records == prior().records
    assert Enum.any?(timed.diagnostics, &(&1.code == :bound_exceeded))
    assert_receive {:worker, worker}
    refute Process.alive?(worker)
  end

  test "default drop strips original messages but preserves raw conflicting duplicate diagnostics" do
    first = event("duplicate")
    second = %{first | "message" => first["message"] <> " "}
    transport = client(fn _, _ -> page([first, first, second]) end)
    capture = enrich(prior(), transport, content: :drop)
    encoded = Jason.encode!(Evidence.to_wire(capture))
    refute encoded =~ "resourceSpans"
    refute encoded =~ "synthetic-token"
    assert Enum.any?(capture.diagnostics, &(&1.code == :conflicting_duplicate))

    assert Enum.map(capture.records, & &1.id) |> Enum.uniq() |> length() ==
             length(capture.records)
  end

  test "missing explicit credentials becomes unavailable without environment resolution" do
    {:ok, bare} =
      CloudWatchClient.new(region: "us-east-1", transport: fn _ -> flunk("called") end)

    capture = enrich(prior(), bare)
    assert capture.records == prior().records
    assert List.last(capture.sources).status == :unavailable
  end

  test "malformed OTLP containers stay raw without aborting valid sibling records" do
    malformed =
      for resource <- [true, [], "bad", %{"attributes" => true}] do
        raw = %{
          "resourceSpans" => [%{"resource" => resource, "scopeSpans" => [%{"spans" => [span()]}]}]
        }

        %{event("malformed") | "message" => Jason.encode!(raw)}
      end

    capture = enrich(prior(), client(fn _, _ -> page(malformed ++ [event("good")]) end))
    assert List.last(capture.records).native_id == "good"
    assert length(capture.correlations) == 1
    assert length(capture.records) == 6
    assert List.last(capture.sources).status == :partial
  end

  test "a fitting prior remains intact when source metadata cannot fit" do
    capture =
      enrich(prior(), client(fn _, _ -> flunk("source should not open") end), max_bytes: 1_500)

    assert capture.records == prior().records
    assert capture.sources == prior().sources
    assert Enum.any?(capture.diagnostics, &(&1.code == :capture_gap and &1.source_id == nil))
    assert byte_size(Jason.encode!(Evidence.to_wire(capture))) <= 1_500
  end

  test "client inspection omits signing credentials" do
    client = client(fn _, _ -> page([]) end)
    inspected = inspect(client)
    refute inspected =~ "synthetic-key"
    refute inspected =~ "synthetic-secret"
    refute inspected =~ "synthetic-token"
  end

  test "coverage metadata cannot evict a fitting prior at a tight byte boundary" do
    prior = prior()
    limit = byte_size(Jason.encode!(Evidence.to_wire(prior))) + 1
    {:ok, options} = Options.new(content: :retain, max_bytes: limit)
    client = client(fn _, _ -> flunk("bounded before transport") end)

    assert {:error, %Evidence.Error{code: :bound_exceeded}} =
             CloudWatch.enrich(prior, query(), options, client: client)
  end

  test "malformed AWS JSON responses preserve prior evidence without exposing response bodies" do
    for body <- ["private-invalid-json", "[]", "null", "42", "true"] do
      capture = enrich(prior(), client(fn _, _ -> {:raw, 200, body} end))
      assert capture.records == prior().records
      assert List.last(capture.sources).status == :unavailable
      refute Jason.encode!(Evidence.to_wire(capture)) =~ "private-invalid-json"
    end
  end

  test "caller cancellation terminates blocked credential and transport workers" do
    owner = self()

    for stage <- [:credentials, :transport] do
      block = fn ->
        send(owner, {:blocked_worker, self()})
        receive do: (:finish -> {:error, :synthetic})
      end

      client =
        case stage do
          :credentials ->
            {:ok, client} = CloudWatchClient.new(region: "us-east-1", credentials: block)
            client

          :transport ->
            client(fn _, _ -> block.() end)
        end

      caller = spawn(fn -> enrich(prior(), client, timeout_ms: 100) end)
      on_exit(fn -> Process.exit(caller, :kill) end)
      assert_receive {:blocked_worker, worker}, 1_000
      on_exit(fn -> Process.exit(worker, :kill) end)
      monitor = Process.monitor(worker)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 500
      refute Process.alive?(worker)
    end
  end

  test "an abruptly exiting request worker cannot crash its surviving caller" do
    {:ok, client} =
      CloudWatchClient.new(
        region: "us-east-1",
        credentials: fn -> Process.exit(self(), :kill) end
      )

    capture = enrich(prior(), client)
    assert capture.records == prior().records
    assert List.last(capture.sources).status == :unavailable
  end

  defp enrich(prior, client, opts \\ [], query \\ query()) do
    {:ok, options} = Options.new(Keyword.put_new(opts, :content, :retain))
    assert {:ok, capture} = CloudWatch.enrich(prior, query, options, client: client)
    capture
  end

  defp client(fun) do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case fun.(conn, Jason.decode!(body)) do
        {:raw, status, body} -> aws_response(conn, status, body)
        {status, response} -> aws_response(conn, status, Jason.encode!(response))
        response -> aws_response(conn, 200, Jason.encode!(response))
      end
    end

    {:ok, client} =
      CloudWatchClient.new(
        region: "us-east-1",
        credentials: %{
          access_key_id: "synthetic-key",
          secret_access_key: "synthetic-secret",
          security_token: "synthetic-token"
        },
        transport: plug
      )

    client
  end

  defp aws_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/x-amz-json-1.1")
    |> Plug.Conn.send_resp(status, body)
  end

  defp prior do
    {:ok, capture} =
      Capture.new(
        %{
          capture_id: "prior",
          provider: :agentcore,
          session_id: "s",
          started_at: ~U[2026-01-01 00:00:00Z],
          ended_at: ~U[2026-01-01 00:00:01Z],
          sources: [
            %{
              id: "local",
              kind: :rma_local,
              scope: "s",
              status: :complete,
              pages: 1,
              records_seen: 1
            }
          ],
          records: [
            %{
              id: "invocation",
              source_id: "local",
              ordinal: 1,
              observed_at: ~U[2026-01-01 00:00:00Z],
              invocation_id: "invocation",
              kind: :local,
              payload: %{type: :invocation_started, invocation_id: "invocation"}
            }
          ]
        },
        content: :retain
      )

    capture
  end

  defp query do
    {:ok, query} = Query.new(query_attrs())
    query
  end

  defp query_attrs,
    do: %{
      region: "us-east-1",
      log_group: "/example/agent",
      from: ~U[2026-01-01 00:00:00Z],
      to: ~U[2026-01-01 00:01:00Z],
      session_id: "s"
    }

  defp page(events, token \\ nil),
    do: if(token, do: %{"events" => events, "nextToken" => token}, else: %{"events" => events})

  defp session(id), do: [%{"key" => "session.id", "value" => %{"stringValue" => id}}]

  defp span(overrides \\ %{}),
    do:
      Map.merge(
        %{
          "traceId" => String.duplicate("a", 32),
          "spanId" => String.duplicate("1", 16),
          "name" => "synthetic operation",
          "startTimeUnixNano" => "100",
          "endTimeUnixNano" => "200",
          "attributes" => session("s")
        },
        overrides
      )

  defp event(id, span \\ span()),
    do: %{
      "eventId" => id,
      "logStreamName" => "example",
      "timestamp" => 1_767_225_600_000,
      "ingestionTime" => 1_767_225_601_000,
      "message" =>
        Jason.encode!(%{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => [span]}]}]})
    }
end
