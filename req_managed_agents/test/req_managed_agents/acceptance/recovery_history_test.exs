defmodule ReqManagedAgents.Acceptance.RecoveryHistoryTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Acceptance.{Assertion, Recovery}
  alias ReqManagedAgents.Evidence
  alias ReqManagedAgents.Evidence.{Artifact, Diagnostic}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.{Client, History}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.History.Request

  @tag :tmp_dir
  test "primary endpoint recovery survives artifact bytes without adding payload thread fields",
       %{tmp_dir: dir} do
    capture = history()
    assert capture.diagnostics == []
    assert {:ok, ref} = Artifact.write(capture, dir)
    bytes = File.read!(Path.join(dir, ref.relative_path))
    assert ref.sha256 == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert {:ok, restored} = bytes |> Jason.decode!() |> Evidence.from_wire()
    assert Enum.map(restored.records, & &1.payload) == [descriptor() | events()]
    assert {:ok, assertion} = Recovery.assess(restored, "lookup", %{"key" => "private-value"})
    assert assertion.outcome == :passed
    [descriptor | reads] = restored.records
    assert assertion.evidence == Enum.map(reads ++ [descriptor], &reference/1)

    for ref <- assertion.evidence do
      assert Enum.any?(restored.records, &(reference(&1) == ref))
    end

    report = Jason.encode!(Assertion.to_wire(assertion))
    refute report =~ "private-value"
    refute report =~ "use-one"
    refute report =~ "primary"
  end

  test "long session identities qualify only their hashed enumeration scope" do
    session = String.duplicate("s", 1024)

    capture =
      history(session: session, descriptors: [Map.put(descriptor(), "session_id", session)])

    scope = "threads:" <> Base.encode16(:crypto.hash(:sha256, session))
    assert Enum.any?(capture.sources, &(&1.scope == scope))
    assert_outcome(capture, :passed)
    assert_outcome(map_source(capture, scope, &%{&1 | scope: "threads:wrong"}), :inconclusive)
  end

  test "declared custom and MCP result keys stay within their native family" do
    for {use_type, result_type, key} <- [
          {"agent.custom_tool_use", "user.custom_tool_result", "custom_tool_use_id"},
          {"agent.mcp_tool_use", "agent.mcp_tool_result", "mcp_tool_use_id"}
        ] do
      records =
        Enum.map(events(), fn event ->
          if event["type"] == "agent.tool_use" do
            Map.put(event, "type", use_type)
          else
            event
            |> Map.put("type", result_type)
            |> Map.delete("tool_use_id")
            |> Map.put(key, event["tool_use_id"])
          end
        end)

      assert_outcome(history(events: records), :passed)

      wrong_link =
        List.update_at(records, 1, &(&1 |> Map.delete(key) |> Map.put("tool_use_id", "use-one")))

      assert_outcome(history(events: wrong_link), :inconclusive)
    end
  end

  test "ordinary children do not make the primary ambiguous and native hints may agree" do
    child = %{descriptor() | "id" => "child", "parent_thread_id" => "primary"}

    for records <- [
          events(),
          Enum.map(
            events(),
            &Map.merge(&1, %{
              "session_id" => "s",
              "thread_id" => "primary",
              "session_thread_id" => "primary"
            })
          )
        ] do
      assert_outcome(history(descriptors: [descriptor(), child], events: records), :passed)
    end
  end

  test "missing endpoint provenance and condensed session records stay inconclusive" do
    capture = history()
    enumeration = Enum.find(capture.sources, &(&1.scope == "sessions/s/threads"))

    for changed <- [
          history(descriptors: [], session_events: events()),
          %{
            capture
            | sources: Enum.reject(capture.sources, &(&1.id == enumeration.id)),
              records: Enum.reject(capture.records, &(&1.source_id == enumeration.id))
          },
          map_source(capture, "sessions/s/threads", &%{&1 | scope: "fabricated"}),
          map_source(capture, "primary", &%{&1 | scope: "s"}),
          %{
            capture
            | records:
                List.update_at(capture.records, 0, fn record ->
                  %{record | payload: Map.put(record.payload, "id", "different")}
                end)
          },
          map_source(capture, "primary", &%{&1 | kind: :claude_session})
        ] do
      assert_outcome(changed, :inconclusive)
    end
  end

  test "native descriptor shape and primary identity must be unique" do
    for descriptors <- [
          [Map.put(descriptor(), "session_id", "other")],
          [Map.put(descriptor(), "type", "other")],
          [Map.delete(descriptor(), "parent_thread_id")],
          [Map.put(descriptor(), "parent_thread_id", "")],
          [Map.put(descriptor(), "parent_thread_id", 5)],
          [Map.put(descriptor(), "parent_thread_id", "parent")],
          [descriptor(), %{"type" => "session_thread", "id" => "child", "session_id" => "s"}],
          [descriptor(), %{descriptor() | "id" => "second"}],
          [descriptor(), descriptor()],
          [descriptor(), %{descriptor() | "parent_thread_id" => "parent"}]
        ] do
      assert_outcome(history(descriptors: descriptors), :inconclusive)
    end

    assert_outcome(history(), :passed)
  end

  test "present payload identity must agree even when another hint is valid" do
    for change <- [
          &Map.put(&1, "session_id", "other"),
          &Map.put(&1, "session_id", nil),
          &Map.put(&1, "thread_id", "other"),
          &Map.put(&1, "session_thread_id", "other"),
          &Map.merge(&1, %{"session_thread_id" => "primary", "thread_id" => "other"}),
          &Map.put(&1, "thread_id", nil),
          &Map.put(&1, "thread_id", ""),
          &Map.put(&1, "session_thread_id", []),
          &Map.merge(&1, %{"session_thread_id" => "primary", "thread_id" => nil})
        ],
        index <- 0..3 do
      assert_outcome(history(events: List.update_at(events(), index, change)), :inconclusive)
    end

    assert_outcome(history(), :passed)
  end

  test "supporting coverage and diagnostics remain required and preserved" do
    capture = history()

    for scope <- ["sessions/s/threads", "primary"],
        status <- [:partial, :unavailable, :not_requested] do
      assert_outcome(map_source(capture, scope, &%{&1 | status: status}), :inconclusive)
    end

    for scope <- [nil, "sessions/s/threads", "primary"] do
      source = Enum.find(capture.sources, &(&1.scope == scope))

      {:ok, diagnostic} =
        Diagnostic.new(%{code: :unsupported_record, source_id: source && source.id})

      changed = %{capture | diagnostics: [diagnostic]}
      assert_outcome(changed, :inconclusive)
      assert changed.diagnostics == [diagnostic]
    end

    assert_outcome(history(descriptors: []), :inconclusive)
    assert_outcome(capture, :passed)
  end

  test "duplicate endpoint or enumeration sources cannot supply qualification" do
    capture = history()

    for scope <- ["primary", "sessions/s/threads"] do
      source = Enum.find(capture.sources, &(&1.scope == scope))
      duplicate = %{source | id: "duplicate-source"}
      assert_outcome(%{capture | sources: capture.sources ++ [duplicate]}, :inconclusive)
    end
  end

  test "native pairs retain exact arguments, count, links, outcomes and strict ordering" do
    for records <- [
          List.update_at(events(), 2, &Map.put(&1, "input", %{"key" => "different"})),
          events() ++
            [
              Map.put(hd(events()), "id", "third-use"),
              Enum.at(events(), 1)
              |> Map.put("id", "third-result")
              |> Map.put("tool_use_id", "third-use")
            ],
          List.update_at(events(), 2, &Map.put(&1, "processed_at", time(1))),
          List.update_at(events(), 2, &Map.put(&1, "processed_at", time(0))),
          List.update_at(events(), 3, &Map.delete(&1, "tool_use_id")),
          List.update_at(events(), 3, &Map.put(&1, "is_error", "false")),
          Enum.map(events(), fn event ->
            if Map.has_key?(event, "is_error"),
              do: Map.update!(event, "is_error", &(!&1)),
              else: event
          end)
        ] do
      assert_outcome(history(events: records), :inconclusive)
    end
  end

  test "a child or condensed session result cannot repair a missing primary result" do
    child = %{descriptor() | "id" => "child", "parent_thread_id" => "primary"}
    missing = List.delete_at(events(), 3)

    for child_events <- [[List.last(events())], events()] do
      assert_outcome(
        history(
          descriptors: [descriptor(), child],
          events: missing,
          child_events: child_events,
          session_events: events()
        ),
        :inconclusive
      )
    end

    other = Enum.map(events(), &Map.put(&1, "session_id", "other"))
    assert_outcome(history(events: other), :inconclusive)
  end

  defp assert_outcome(capture, outcome) do
    assert {:ok, restored} = capture |> Evidence.to_wire() |> Evidence.from_wire()
    assert {:ok, assertion} = Recovery.assess(restored, "lookup", %{"key" => "private-value"})
    assert assertion.outcome == outcome
  end

  defp history(opts \\ []) do
    owner = self()
    session = Keyword.get(opts, :session, "s")
    prefix = "/v1/sessions/#{session}"

    plug = fn conn ->
      assert conn.method == "GET"
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params == %{"limit" => "100"}
      send(owner, {:requested, conn.request_path})

      records =
        cond do
          conn.request_path == prefix <> "/events" ->
            Keyword.get(opts, :session_events, [])

          conn.request_path == prefix <> "/threads" ->
            Keyword.get(opts, :descriptors, [descriptor()])

          conn.request_path == prefix <> "/threads/primary/events" ->
            Keyword.get(opts, :events, events())

          conn.request_path == prefix <> "/threads/child/events" ->
            Keyword.get(opts, :child_events, [])

          conn.request_path == prefix <> "/threads/second/events" ->
            []
        end

      Req.Test.json(conn, %{"data" => records, "next_page" => nil})
    end

    client = Client.new(api_key: "test-key", req_options: [plug: plug, retry: false])
    {:ok, request} = Request.new(client: client, options: [content: :retain])
    assert {:ok, capture} = History.fetch(session, request)
    session_path = prefix <> "/events"
    threads_path = prefix <> "/threads"
    assert_received {:requested, ^session_path}
    assert_received {:requested, ^threads_path}

    for descriptor <- Keyword.get(opts, :descriptors, [descriptor()]) |> Enum.uniq_by(& &1["id"]) do
      path = prefix <> "/threads/#{descriptor["id"]}/events"
      assert_received {:requested, ^path}
    end

    capture
  end

  defp map_source(capture, scope, fun),
    do: %{
      capture
      | sources:
          Enum.map(capture.sources, fn source ->
            if source.scope == scope, do: fun.(source), else: source
          end)
    }

  defp reference(record), do: record.source_id <> ":" <> record.id

  defp descriptor,
    do: %{
      "type" => "session_thread",
      "id" => "primary",
      "session_id" => "s",
      "parent_thread_id" => nil
    }

  defp time(second), do: "2026-01-01T00:00:0#{second}Z"

  defp events do
    [
      %{
        "type" => "agent.tool_use",
        "id" => "use-one",
        "name" => "lookup",
        "input" => %{"key" => "private-value"},
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
        "input" => %{"key" => "private-value"},
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
  end
end
