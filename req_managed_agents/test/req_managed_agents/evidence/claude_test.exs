defmodule ReqManagedAgents.Evidence.ClaudeTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Client
  alias ReqManagedAgents.Evidence
  alias ReqManagedAgents.Evidence.{Claude, Fetch, LocalRecord, Options, Recorder}

  test "continues empty intermediate pages on session, enumeration and thread histories" do
    client =
      transport(fn path, page ->
        case {path, page} do
          {"/v1/sessions/s/events", nil} -> page([], "session-next")
          {"/v1/sessions/s/events", "session-next"} -> page([event("session")])
          {"/v1/sessions/s/threads", nil} -> page([], "threads-next")
          {"/v1/sessions/s/threads", "threads-next"} -> page([%{"id" => "child"}])
          {"/v1/sessions/s/threads/child/events", nil} -> page([], "child-next")
          {"/v1/sessions/s/threads/child/events", "child-next"} -> page([event("child")])
        end
      end)

    capture = fetch(client)
    assert Enum.map(events(capture), & &1.native_id) == ["session", "child"]
    assert Enum.sum(Enum.map(capture.sources, & &1.pages)) == 6
    assert Enum.all?(capture.sources, &(&1.status == :complete))
  end

  test "long cursor cycles retain evidence and mark the affected source partial" do
    client =
      transport(fn
        "/v1/sessions/s/events", nil -> page([event("first")], "a")
        "/v1/sessions/s/events", "a" -> page([], "b")
        "/v1/sessions/s/events", "b" -> page([event("last")], "a")
        "/v1/sessions/s/threads", nil -> page([])
      end)

    capture = fetch(client)
    assert Enum.map(events(capture), & &1.native_id) == ["first", "last"]
    assert [%{pages: 3, status: :partial, reason: :cursor_cycle}] = session_sources(capture)
    assert Enum.any?(capture.diagnostics, &(&1.code == :cursor_cycle))
  end

  test "page errors retain earlier records without retaining the error body" do
    client =
      transport(fn
        "/v1/sessions/s/events", nil -> page([event("first")], "next")
        "/v1/sessions/s/events", "next" -> {:error, 403, %{"secret" => "credential-secret"}}
        "/v1/sessions/s/threads", nil -> {:error, 403, %{}}
      end)

    capture = fetch(client)
    assert [%{native_id: "first"}] = events(capture)
    assert Enum.all?(capture.sources, &(&1.status in [:partial, :unavailable]))
    assert Enum.any?(capture.sources, &(&1.kind == :claude_thread and &1.status == :unavailable))
    refute Jason.encode!(Evidence.to_wire(capture)) =~ "credential-secret"
  end

  test "malformed page and cursor shapes cannot claim complete coverage" do
    for body <- [
          %{},
          %{"data" => nil},
          %{"data" => %{}},
          page([event("ok")], 42),
          page([event("ok")], ""),
          page([event("ok")], "  ")
        ] do
      client =
        transport(fn
          "/v1/sessions/s/events", nil -> body
          "/v1/sessions/s/threads", nil -> page([])
        end)

      capture = fetch(client)
      assert [%{status: :partial, reason: :incomplete_retrieval}] = session_sources(capture)
      assert Enum.any?(capture.diagnostics, &(&1.code == :incomplete_retrieval))
      if is_list(body["data"]), do: assert(Enum.map(events(capture), & &1.native_id) == ["ok"])
    end
  end

  test "aggregate page budget includes enumeration and each thread" do
    client =
      transport(fn
        "/v1/sessions/s/events", nil -> page([event("session")])
        "/v1/sessions/s/threads", nil -> page([%{"id" => "one"}, %{"id" => "two"}])
        "/v1/sessions/s/threads/one/events", nil -> page([event("one")], "next")
      end)

    capture = fetch(client, max_pages: 3)
    assert Enum.sum(Enum.map(capture.sources, & &1.pages)) == 3
    assert Enum.map(events(capture), & &1.native_id) == ["session", "one"]
    assert Enum.count(capture.sources, &(&1.status == :partial)) >= 2
    assert Enum.any?(capture.diagnostics, &(&1.code == :bound_exceeded))
  end

  test "record budget counts thread descriptors and stops requests across sources" do
    client =
      transport(fn
        "/v1/sessions/s/events", nil -> page([event("session")])
        "/v1/sessions/s/threads", nil -> page([%{"id" => "one"}, %{"id" => "two"}])
      end)

    capture = fetch(client, max_records: 2)
    assert [%{native_id: "session"}] = events(capture)
    assert Enum.sum(Enum.map(capture.sources, & &1.pages)) == 2
    assert Enum.any?(capture.diagnostics, &(&1.code == :bound_exceeded))
  end

  test "oversized retained page stops at the byte budget and keeps a valid prefix" do
    huge = Map.put(event("huge"), "text", String.duplicate("private", 5_000))

    client =
      transport(fn
        "/v1/sessions/s/events", nil -> page([event("small"), huge], "next")
      end)

    capture = fetch(client, max_bytes: 5_000)
    assert [%{native_id: "small"}] = events(capture)
    assert byte_size(Jason.encode!(Evidence.to_wire(capture))) <= 5_000
    assert Enum.any?(capture.diagnostics, &(&1.code == :bound_exceeded))
  end

  test "deadline terminates an in-flight request and preserves preceding pages" do
    owner = self()

    client =
      transport(fn
        "/v1/sessions/s/events", nil ->
          page([event("first")], "slow")

        "/v1/sessions/s/events", "slow" ->
          send(owner, {:slow_request, self()})
          Process.sleep(5_000)
          page([event("late")])
      end)

    started = System.monotonic_time(:millisecond)
    capture = fetch(client, timeout_ms: 100)
    assert System.monotonic_time(:millisecond) - started < 1_000
    assert_receive {:slow_request, worker}
    refute Process.alive?(worker)
    assert [%{native_id: "first"}] = events(capture)
    assert Enum.any?(capture.diagnostics, &(&1.code == :bound_exceeded))
  end

  test "retains provider fields and distinct thread occurrences without assigning attempts" do
    records = [
      %{
        "id" => "start",
        "type" => "span.model_request_start",
        "processed_at" => "2026-01-01T00:00:00Z"
      },
      %{
        "id" => "end",
        "type" => "span.model_request_end",
        "model_request_start_id" => "start",
        "model_usage" => %{"input_tokens" => 12},
        "processed_at" => "2026-01-01T00:00:01Z"
      },
      %{
        "id" => "tool",
        "type" => "agent.tool_result",
        "tool_use_id" => "call",
        "output" => "built-in"
      },
      %{
        "id" => "mcp",
        "type" => "agent.mcp_tool_result",
        "mcp_tool_use_id" => "mcp-call",
        "content" => "mcp"
      },
      %{
        "id" => "custom",
        "type" => "user.custom_tool_result",
        "custom_tool_use_id" => "custom-call",
        "session_thread_id" => "one",
        "content" => "custom"
      }
    ]

    client =
      transport(fn
        "/v1/sessions/s/events", nil -> page(records)
        "/v1/sessions/s/threads", nil -> page([%{"id" => "one"}, %{"id" => "two"}])
        "/v1/sessions/s/threads/one/events", nil -> page([event("same")])
        "/v1/sessions/s/threads/two/events", nil -> page([event("same")])
      end)

    capture = fetch(client)
    assert Enum.take(Enum.map(events(capture), & &1.payload), 5) == records
    duplicates = Enum.filter(events(capture), &(&1.native_id == "same"))
    assert length(duplicates) == 2
    assert length(Enum.uniq_by(duplicates, & &1.source_id)) == 2
    assert Enum.all?(events(capture), &(&1.attempt_id == nil and &1.invocation_id == nil))
    assert hd(events(capture)).occurred_at == ~U[2026-01-01 00:00:00Z]
    assert {:ok, _} = capture |> Evidence.to_wire() |> Evidence.from_wire()
  end

  test "unknown records and malformed optional metadata retain valid siblings" do
    raw = [
      %{"id" => ["bad"], "type" => "agent.message", "processed_at" => 13},
      %{"id" => "unknown", "type" => "future.event", "secret" => "hidden"},
      event("valid"),
      "bad-record"
    ]

    client =
      transport(fn
        "/v1/sessions/s/events", nil -> page(raw)
        "/v1/sessions/s/threads", nil -> page([])
      end)

    capture = fetch(client)
    assert Enum.map(events(capture), & &1.native_id) == [nil, "unknown", "valid"]
    assert Enum.map(events(capture), & &1.payload) == Enum.take(raw, 3)
    assert Enum.any?(capture.diagnostics, &(&1.code == :unsupported_record))
    assert [%{status: :partial}] = session_sources(capture)
    dropped = fetch(client, content: :drop)
    refute Jason.encode!(Evidence.to_wire(dropped)) =~ "hidden"
    assert Enum.any?(events(dropped), &(&1.native_id == "valid"))
  end

  test "prior Recorder snapshot preserves identities and references under content policy" do
    {:ok, opts} = Options.new(content: :retain)
    {:ok, recorder} = Recorder.start_link(opts)
    on_exit(fn -> if Process.alive?(recorder), do: GenServer.stop(recorder) end)
    :ok = Recorder.context(recorder, :managed, "s")
    {:ok, local} = LocalRecord.new(%{type: :invocation_start, invocation_id: "invocation"})
    :ok = Recorder.emit(recorder, local)

    for type <- [:attempt_start, :attempt_end] do
      {:ok, attempt} =
        LocalRecord.new(%{type: type, invocation_id: "invocation", attempt_id: "attempt"})

      :ok = Recorder.emit(recorder, attempt)
    end

    :ok = Recorder.native(recorder, Map.put(event("live"), "text", "local-secret"))
    {:ok, prior} = Recorder.snapshot(recorder)
    assert Enum.count(prior.records, &(&1.attempt_id == "attempt")) == 2
    first = hd(prior.records)

    {:ok, prior} =
      Evidence.Capture.new(
        %{
          prior
          | correlations: [
              %{
                from_record_id: first.id,
                relation: :application,
                target: %{namespace: :application, request_id: "request"},
                evidence_record_ids: [first.id]
              }
            ]
        },
        content: :retain
      )

    client =
      transport(fn
        "/v1/sessions/s/events", nil -> page([event("history")])
        "/v1/sessions/s/threads", nil -> page([])
      end)

    {:ok, config} = Fetch.new(client: client, prior: prior, options: [content: :retain])
    assert {:ok, capture} = Claude.fetch("s", config)
    assert Enum.take(capture.records, length(prior.records)) == prior.records
    assert capture.correlations == prior.correlations
    assert capture.capture_id == prior.capture_id
    {:ok, config} = Fetch.new(client: client, prior: prior)
    assert {:ok, dropped} = Claude.fetch("s", config)
    refute Jason.encode!(Evidence.to_wire(dropped)) =~ "local-secret"
    assert {:error, _} = Claude.fetch("different", config)
    assert {:error, _} = Fetch.new(client: client, prior: %{prior | provider: :agentcore})
  end

  test "configuration rejects malformed clients, options and prior captures" do
    for opts <- [
          [],
          [client: %{}],
          [client: transport(fn _, _ -> page([]) end), options: [max_pages: 0]],
          [client: nil],
          [unexpected: true]
        ] do
      assert {:error, %Evidence.Error{}} = Fetch.new(opts)
    end

    {:ok, config} = Fetch.new(client: transport(fn _, _ -> flunk("invalid input requested") end))
    assert {:error, _} = Claude.fetch("", config)
    assert {:error, _} = Claude.fetch(nil, config)
  end

  test "enumeration retains descriptors and retrieves valid siblings of malformed IDs" do
    descriptor = %{
      "id" => "child",
      "session_id" => "s",
      "parent_thread_id" => "primary",
      "status" => "idle",
      "private" => "descriptor-secret"
    }

    client =
      transport(fn
        "/v1/sessions/s/events", nil -> page([])
        "/v1/sessions/s/threads", nil -> page([%{"id" => ["bad"]}, descriptor])
        "/v1/sessions/s/threads/child/events", nil -> page([event("child-event")])
      end)

    retained = fetch(client)
    assert Enum.any?(retained.records, &(&1.payload == descriptor))
    assert [%{native_id: "child-event"}] = events(retained)

    assert Enum.any?(
             retained.sources,
             &(&1.scope == "sessions/s/threads" and &1.status == :partial)
           )

    dropped = fetch(client, content: :drop)
    refute Jason.encode!(Evidence.to_wire(dropped)) =~ "descriptor-secret"
    assert Enum.any?(dropped.records, &(&1.native_id == "child" and &1.content_state == :dropped))
  end

  test "enumeration failure after an empty page is partial rather than unavailable" do
    client =
      transport(fn
        "/v1/sessions/s/events", nil -> page([])
        "/v1/sessions/s/threads", nil -> page([], "next")
        "/v1/sessions/s/threads", "next" -> {:error, 403, %{}}
      end)

    capture = fetch(client)

    assert [%{pages: 2, status: :partial}] =
             Enum.filter(capture.sources, &(&1.kind == :claude_thread))
  end

  test "malformed records consume the aggregate inspection budget" do
    client =
      transport(fn
        "/v1/sessions/s/events", nil -> page([false, "bad", event("unbounded")])
      end)

    capture = fetch(client, max_records: 2)
    assert capture.records == []
    assert Enum.any?(capture.diagnostics, &(&1.code == :bound_exceeded))
  end

  test "thread history cycles and errors preserve already collected siblings" do
    client =
      transport(fn
        "/v1/sessions/s/events", nil -> page([])
        "/v1/sessions/s/threads", nil -> page([%{"id" => "one"}, %{"id" => "two"}])
        "/v1/sessions/s/threads/one/events", nil -> page([event("one")], "same")
        "/v1/sessions/s/threads/one/events", "same" -> page([], "same")
        "/v1/sessions/s/threads/two/events", nil -> page([event("two")], "fail")
        "/v1/sessions/s/threads/two/events", "fail" -> {:error, 403, %{}}
      end)

    capture = fetch(client)
    assert Enum.map(events(capture), & &1.native_id) == ["one", "two"]
    assert Enum.any?(capture.sources, &(&1.scope == "one" and &1.reason == :cursor_cycle))
    assert Enum.any?(capture.sources, &(&1.scope == "two" and &1.status == :partial))
  end

  test "prior content is dropped before applying byte admission to new history" do
    client =
      transport(fn
        "/v1/sessions/s/events", nil ->
          page([Map.put(event("live"), "text", String.duplicate("large", 2_000))])

        "/v1/sessions/s/threads", nil ->
          page([])
      end)

    prior = fetch(client)

    next =
      transport(fn
        "/v1/sessions/s/events", nil -> page([event("later")])
        "/v1/sessions/s/threads", nil -> page([])
      end)

    {:ok, config} = Fetch.new(client: next, prior: prior, options: [max_bytes: 5_000])
    assert {:ok, capture} = Claude.fetch("s", config)
    assert Enum.map(events(capture), & &1.native_id) == ["live", "later"]
    assert byte_size(Jason.encode!(Evidence.to_wire(capture))) <= 5_000
  end

  test "default drop preserves documented tool links while removing content" do
    records = [
      %{
        "id" => "mcp-call",
        "type" => "agent.mcp_tool_use",
        "name" => "search",
        "input" => "private-input"
      },
      %{
        "id" => "mcp-result",
        "type" => "agent.mcp_tool_result",
        "mcp_tool_use_id" => "mcp-call",
        "content" => "private-result"
      },
      %{
        "id" => "self-hosted",
        "type" => "user.tool_result",
        "tool_use_id" => "built-in",
        "content" => "private-result"
      },
      %{
        "id" => "confirmation",
        "type" => "user.tool_confirmation",
        "tool_use_id" => "built-in",
        "detail" => "private-approval"
      }
    ]

    client =
      transport(fn
        "/v1/sessions/s/events", nil -> page(records)
        "/v1/sessions/s/threads", nil -> page([])
      end)

    {:ok, config} = Fetch.new(client: client)
    assert {:ok, capture} = Claude.fetch("s", config)

    assert Enum.map(capture.records, & &1.payload) == [
             %{"id" => "mcp-call", "type" => "agent.mcp_tool_use", "name" => "search"},
             %{
               "id" => "mcp-result",
               "type" => "agent.mcp_tool_result",
               "mcp_tool_use_id" => "mcp-call"
             },
             %{"id" => "self-hosted", "type" => "user.tool_result", "tool_use_id" => "built-in"},
             %{
               "id" => "confirmation",
               "type" => "user.tool_confirmation",
               "tool_use_id" => "built-in"
             }
           ]

    refute Jason.encode!(Evidence.to_wire(capture)) =~ "private-"
    assert Enum.map(fetch(client).records, & &1.payload) == records
  end

  test "unbounded malformed record diagnostics cannot discard an earlier valid record" do
    client =
      transport(fn
        "/v1/sessions/s/events", nil -> page([event("first") | List.duplicate(false, 1_000)])
        "/v1/sessions/s/threads", nil -> page([])
      end)

    capture = fetch(client, max_bytes: 5_000)
    assert [%{native_id: "first"}] = events(capture)
    assert byte_size(Jason.encode!(Evidence.to_wire(capture))) <= 5_000
    assert Enum.any?(capture.diagnostics, &(&1.code == :unsupported_record and &1.count == 1_000))
  end

  test "byte bounds include thread source metadata before opening more histories" do
    ids = Enum.map(1..5, &(Integer.to_string(&1) <> String.duplicate("x", 950)))
    owner = self()

    client =
      transport(fn
        "/v1/sessions/s/events", nil ->
          page([event("first")])

        "/v1/sessions/s/threads", nil ->
          page(Enum.map(ids, &%{"id" => &1}))

        path, nil ->
          send(owner, {:child_requested, path})
          page([])
      end)

    capture = fetch(client, max_bytes: 5_000, content: :drop)
    assert [%{native_id: "first"}] = events(capture)
    assert byte_size(Jason.encode!(Evidence.to_wire(capture))) <= 5_000
    refute Enum.all?(capture.sources, &(&1.status == :complete))
    refute_received {:child_requested, _}
    assert Enum.any?(capture.diagnostics, &(&1.code == :capture_gap))
  end

  test "empty optional native IDs are diagnosed without losing valid records" do
    client =
      transport(fn
        "/v1/sessions/s/events", nil -> page([event(""), event("valid")])
        "/v1/sessions/s/threads", nil -> page([])
      end)

    capture = fetch(client)
    assert [%{id: malformed_id, native_id: nil}, %{native_id: "valid"}] = capture.records

    assert Enum.any?(
             capture.diagnostics,
             &(&1.code == :unsupported_record and &1.record_id == malformed_id)
           )
  end

  test "fitting prior survives when another source cannot be admitted" do
    initial_client =
      transport(fn
        "/v1/sessions/s/events", nil -> page([event("first")])
        "/v1/sessions/s/threads", nil -> page([])
      end)

    prior = fetch(initial_client)
    [record] = prior.records

    {:ok, correlated} =
      Evidence.Capture.new(
        %{
          prior
          | correlations: [
              %{
                from_record_id: record.id,
                relation: :same_session,
                target: %{namespace: :record, id: record.id},
                evidence_record_ids: [record.id]
              }
            ]
        },
        content: :retain
      )

    owner = self()

    client =
      transport(fn path, _ ->
        send(owner, {:unexpected_enrichment, path})
        page([])
      end)

    for prior <- [prior, correlated] do
      assert byte_size(Jason.encode!(Evidence.to_wire(prior))) < 1_500

      {:ok, config} =
        Fetch.new(client: client, prior: prior, options: [content: :retain, max_bytes: 1_500])

      assert {:ok, capture} = Claude.fetch("s", config)
      assert capture.capture_id == prior.capture_id
      assert capture.records == prior.records
      assert capture.correlations == prior.correlations
      assert capture.sources == prior.sources
      assert Enum.any?(capture.diagnostics, &(&1.code == :bound_exceeded and &1.source_id == nil))
      assert Enum.any?(capture.diagnostics, &(&1.code == :capture_gap and &1.source_id == nil))
      assert byte_size(Jason.encode!(Evidence.to_wire(capture))) <= 1_500
      assert {:ok, _} = capture |> Evidence.to_wire() |> Evidence.from_wire()

      {:ok, too_small} =
        Fetch.new(client: client, prior: prior, options: [content: :retain, max_bytes: 200])

      assert {:error, %Evidence.Error{code: :bound_exceeded}} = Claude.fetch("s", too_small)
      refute_received {:unexpected_enrichment, _}
    end
  end

  defp fetch(client, options \\ []) do
    {:ok, config} =
      Fetch.new(client: client, options: Keyword.put_new(options, :content, :retain))

    assert {:ok, capture} = Claude.fetch("s", config)
    capture
  end

  defp transport(fun) do
    plug = fn conn ->
      assert conn.method == "GET"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]
      conn = Plug.Conn.fetch_query_params(conn)

      case fun.(conn.request_path, conn.query_params["page"]) do
        {:error, status, body} -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
        body -> Req.Test.json(conn, body)
      end
    end

    Client.new(api_key: "test-key", req_options: [plug: plug, retry: false])
  end

  defp page(records, cursor \\ nil), do: %{"data" => records, "next_page" => cursor}
  defp event(id), do: %{"id" => id, "type" => "agent.message"}
  defp events(capture), do: Enum.filter(capture.records, &Map.has_key?(&1.payload, "type"))
  defp session_sources(capture), do: Enum.filter(capture.sources, &(&1.kind == :claude_session))
end
