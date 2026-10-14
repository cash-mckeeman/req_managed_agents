defmodule ReqManagedAgents.Evidence.ClaudeNativeEventsTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Evidence
  alias ReqManagedAgents.Evidence.Capture
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Event
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Evidence, as: Claude

  @time "2026-10-13T12:00:00Z"
  @private "PRIVATE_NATIVE_SENTINEL"

  test "thread status round trips retain identity and reason without ending a session" do
    for type <- ~w(session.thread_status_running session.thread_status_idle) do
      payload =
        type
        |> event()
        |> Map.merge(%{
          "session_thread_id" => "sthr_invented",
          "agent_name" => @private,
          "stop_reason" => %{"type" => @private},
          "name" => @private
        })
        |> idle_fields(type)

      safe =
        payload
        |> Map.take(~w(type id processed_at session_thread_id))
        |> safe_idle_fields(type)

      observation = Claude.interpret(payload)
      assert observation.supported?
      refute observation.malformed_metadata?
      assert observation.native_id == "evt_invented"
      assert DateTime.to_iso8601(observation.occurred_at) == @time
      assert Event.classify(payload) == :other

      for kind <- [:claude_session, :claude_thread] do
        restored = round_trip(payload, kind)
        assert hd(restored.records).payload == safe
        refute Enum.any?(restored.diagnostics, &(&1.code == :unsupported_record))
        assert Event.classify(hd(restored.records).payload) == :other
      end
    end

    assert Event.classify(%{
             "type" => "session.status_idle",
             "stop_reason" => %{"type" => "end_turn"}
           }) == :end_turn
  end

  test "usage round trips preserve cumulative nested metadata and exact monetary strings" do
    payload = usage_event()

    safe = %{
      "type" => "session.usage",
      "id" => "evt_invented",
      "processed_at" => @time,
      "usage" => %{
        "active_seconds" => 2.5,
        "cache_creation" => %{
          "ephemeral_1h_input_tokens" => 7,
          "ephemeral_5m_input_tokens" => 11
        },
        "cache_read_input_tokens" => 13,
        "input_tokens" => 17,
        "output_tokens" => 19,
        "list_cost" => %{"amount" => "900719925474099312345", "currency" => "USD"},
        "server_tool_use" => %{"web_fetch_requests" => 23, "web_search_requests" => 29}
      },
      "budget" => %{
        "type" => "limit",
        "max_list_cost" => %{"amount" => "999999999999999999999", "currency" => "USD"}
      }
    }

    assert Claude.interpret(payload).safe_payload == safe
    restored = round_trip(payload, :claude_session)
    assert hd(restored.records).payload == safe
    refute Enum.any?(restored.diagnostics, &(&1.code == :unsupported_record))
    assert Event.classify(hd(restored.records).payload) == :other

    repeated = %{
      attrs(payload, :claude_session)
      | records: [record(payload, 1), record(payload, 2)]
    }

    assert {:ok, capture} = Capture.new(repeated)
    wire = capture |> Evidence.to_wire() |> Jason.encode!() |> Jason.decode!()
    assert {:ok, restored} = Evidence.from_wire(wire)
    assert Enum.map(restored.records, & &1.payload) == [safe, safe]
    refute Enum.any?(restored.diagnostics, &(&1.code == :unsupported_record))
  end

  test "new event required fields are diagnosed while valid siblings survive restoration" do
    for payload <- [
          event("session.thread_status_running") |> Map.put("session_thread_id", "sthr_invented"),
          event("session.thread_status_idle") |> Map.put("session_thread_id", "sthr_invented"),
          usage_event()
        ],
        key <- [
          "id",
          "processed_at",
          if(payload["type"] == "session.usage", do: "usage", else: "session_thread_id")
        ],
        value <- [:absent, nil, "", 1, []] do
      malformed =
        if value == :absent, do: Map.delete(payload, key), else: Map.put(payload, key, value)

      observation = Claude.interpret(malformed)
      assert observation.supported?
      assert observation.malformed_metadata?
      refute Map.has_key?(observation.safe_payload, key)
      restored = round_trip(malformed, :claude_session)
      assert hd(restored.records).validation_issue?
      assert Enum.any?(restored.diagnostics, &(&1.code == :unsupported_record))
      assert hd(restored.records).payload["type"] == payload["type"]
    end
  end

  test "optional usage fields and absent or null budgets are valid" do
    for budget <- [:absent, nil],
        usage <- [
          %{},
          %{
            "active_seconds" => 0,
            "input_tokens" => 0,
            "list_cost" => %{"amount" => "0", "currency" => "USD"}
          }
        ] do
      payload = Map.put(event("session.usage"), "usage", usage)
      payload = if budget == :absent, do: payload, else: Map.put(payload, "budget", budget)
      restored = round_trip(payload, :claude_session)
      refute Enum.any?(restored.diagnostics, &(&1.code == :unsupported_record))
      assert hd(restored.records).payload == Map.delete(payload, "budget")
    end
  end

  test "malformed nested usage and budgets omit bad fields and preserve valid siblings" do
    for {path, bad} <- [
          {["usage", "input_tokens"], -1},
          {["usage", "output_tokens"], 1.5},
          {["usage", "cache_read_input_tokens"], "1"},
          {["usage", "active_seconds"], -0.1},
          {["usage", "active_seconds"], nil},
          {["usage", "cache_creation"], []},
          {["usage", "cache_creation", "ephemeral_1h_input_tokens"], -1},
          {["usage", "cache_creation", "ephemeral_5m_input_tokens"], 1.5},
          {["usage", "server_tool_use"], false},
          {["usage", "server_tool_use", "web_fetch_requests"], -1},
          {["usage", "server_tool_use", "web_search_requests"], nil},
          {["usage", "list_cost", "currency"], "EUR"},
          {["usage", "list_cost", "amount"], "01"},
          {["usage", "list_cost", "amount"], "1.0"},
          {["usage", "list_cost", "amount"], "+1"},
          {["usage", "list_cost", "amount"], "-1"},
          {["usage", "list_cost", "amount"], "1e2"},
          {["usage", "list_cost", "amount"], "1\n"},
          {["usage", "list_cost", "amount"], 1},
          {["usage", "list_cost"], %{"amount" => "0"}},
          {["budget"], %{}},
          {["budget"], []},
          {["budget", "type"], "future"},
          {["budget", "max_list_cost", "amount"], " 1"},
          {["budget", "max_list_cost", "currency"], "usd"}
        ] do
      payload = put_in(usage_event(), path, bad)
      observation = Claude.interpret(payload)
      assert observation.supported?
      assert observation.malformed_metadata?, inspect({path, bad})
      omitted = if "list_cost" in path, do: ["usage", "list_cost"], else: path
      omitted = if hd(path) == "budget", do: ["budget"], else: omitted
      assert get_in(observation.safe_payload, omitted) == nil, inspect({path, bad})

      assert observation.safe_payload["usage"]["cache_read_input_tokens"] ==
               if(path == ["usage", "cache_read_input_tokens"], do: nil, else: 13)

      assert {:ok, capture} = Capture.new(attrs(payload, :claude_session))
      assert hd(capture.records).validation_issue?
      restored = round_trip(payload, :claude_session)
      assert hd(restored.records).payload == observation.safe_payload
      assert Enum.any?(restored.diagnostics, &(&1.code == :unsupported_record))
    end
  end

  test "thread reason metadata accepts type-only objects and diagnoses malformed values" do
    for reason <- ["end_turn", %{}, %{"type" => ""}, %{"type" => 1}, []] do
      payload =
        "session.thread_status_idle"
        |> event()
        |> Map.merge(%{"session_thread_id" => "sthr_invented", "stop_reason" => reason})

      assert {:ok, capture} = Capture.new(attrs(payload, :claude_thread))
      assert hd(capture.records).validation_issue?
      restored = round_trip(payload, :claude_thread)
      assert Enum.any?(restored.diagnostics, &(&1.code == :unsupported_record))
      refute Map.has_key?(hd(restored.records).payload, "stop_reason")
    end
  end

  test "retain restores raw native content while drop and unknown events stay conservative" do
    for payload <- [
          event("session.thread_status_running") |> Map.put("session_thread_id", "sthr_invented"),
          event("session.thread_status_idle")
          |> Map.put("session_thread_id", "sthr_invented")
          |> idle_fields("session.thread_status_idle"),
          usage_event(),
          event("session.future")
        ] do
      payload = Map.put(payload, "unknown", %{"body" => @private})
      restored = round_trip(payload, :claude_session, content: :retain)
      assert hd(restored.records).payload == payload
      assert Jason.encode!(Evidence.to_wire(restored)) =~ @private
      assert hd(restored.records).content_state == :retained
      dropped = round_trip(payload, :claude_session)
      refute Jason.encode!(Evidence.to_wire(dropped)) =~ @private
    end

    unknown = round_trip(event("session.future"), :claude_session)
    assert hd(unknown.records).payload == %{}
    assert Enum.any?(unknown.diagnostics, &(&1.code == :unsupported_record))
  end

  defp event(type), do: %{"type" => type, "id" => "evt_invented", "processed_at" => @time}

  defp idle_fields(payload, "session.thread_status_idle") do
    Map.merge(payload, %{
      "stop_reason" => %{"type" => "end_turn", "content" => @private},
      "stop_details" => nil
    })
  end

  defp idle_fields(payload, _), do: payload

  defp safe_idle_fields(payload, "session.thread_status_idle"),
    do: Map.put(payload, "stop_reason", %{"type" => "end_turn"})

  defp safe_idle_fields(payload, _), do: payload

  defp usage_event do
    Map.merge(event("session.usage"), %{
      "usage" => %{
        "active_seconds" => 2.5,
        "cache_creation" => %{
          "ephemeral_1h_input_tokens" => 7,
          "ephemeral_5m_input_tokens" => 11,
          "unknown" => @private
        },
        "cache_read_input_tokens" => 13,
        "input_tokens" => 17,
        "output_tokens" => 19,
        "list_cost" => %{
          "amount" => "900719925474099312345",
          "currency" => "USD",
          "unknown" => @private
        },
        "server_tool_use" => %{
          "web_fetch_requests" => 23,
          "web_search_requests" => 29,
          "unknown" => @private
        },
        "unknown" => @private
      },
      "budget" => %{
        "type" => "limit",
        "max_list_cost" => %{
          "amount" => "999999999999999999999",
          "currency" => "USD",
          "unknown" => @private
        },
        "unknown" => @private
      },
      "unknown" => @private
    })
  end

  defp round_trip(payload, kind, options \\ []) do
    assert {:ok, capture} = Capture.new(attrs(payload, kind), options)
    wire = capture |> Evidence.to_wire() |> Jason.encode!() |> Jason.decode!()
    assert {:ok, restored} = Evidence.from_wire(wire)
    restored
  end

  defp attrs(payload, kind) do
    %{
      capture_id: "capture_invented",
      provider: :managed,
      session_id: "sesn_invented",
      started_at: @time,
      ended_at: @time,
      sources: [%{id: "source_invented", kind: kind, scope: "sesn_invented", status: :complete}],
      records: [record(payload, 1)]
    }
  end

  defp record(payload, ordinal) do
    %{
      id: "record_#{ordinal}",
      source_id: "source_invented",
      ordinal: ordinal,
      observed_at: @time,
      clock: :wall,
      kind: :native,
      payload: payload
    }
  end
end
