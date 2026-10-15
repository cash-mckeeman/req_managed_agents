defmodule ReqManagedAgents.Evidence.ClaudeActivityTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Evidence
  alias ReqManagedAgents.Evidence.Capture
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Event
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Evidence, as: Claude

  @time "2026-01-01T00:00:00Z"
  @private "PRIVATE_ACTIVITY_SENTINEL"
  @types ~w(agent.thinking session.thread_created agent.thread_message_sent agent.thread_message_received)

  test "thinking retains progress metadata without content" do
    payload = event("agent.thinking")

    assert_projection(payload, %{
      "type" => "agent.thinking",
      "id" => "evt_invented",
      "processed_at" => @time
    })
  end

  test "thread creation retains child identity without ancestry" do
    payload = Map.put(event("session.thread_created"), "session_thread_id", "sthr_child")

    assert_projection(payload, %{
      "type" => "session.thread_created",
      "id" => "evt_invented",
      "processed_at" => @time,
      "session_thread_id" => "sthr_child"
    })
  end

  test "thread messages preserve only their directional peer" do
    for {type, peer, opposite} <- directions() do
      payload =
        type
        |> event()
        |> Map.merge(%{peer => "sthr_peer", opposite => "sthr_wrong_direction"})

      assert_projection(payload, %{
        "type" => type,
        "id" => "evt_invented",
        "processed_at" => @time,
        peer => "sthr_peer"
      })

      wrong_direction = Map.delete(payload, peer)
      observation = Claude.interpret(wrong_direction)
      assert observation.supported?
      assert observation.malformed_metadata?
      assert observation.safe_payload == Map.take(payload, ~w(type id processed_at))
      assert_diagnosed(wrong_direction, observation.safe_payload)
    end
  end

  test "known malformed activity diagnoses missing required metadata" do
    for payload <- activities(),
        key <- required_keys(payload["type"]),
        bad <- [:absent, nil, "", 1, [], String.duplicate("a", 1025), "bad\0id"] do
      malformed =
        if bad == :absent, do: Map.delete(payload, key), else: Map.put(payload, key, bad)

      observation = Claude.interpret(malformed)
      assert observation.supported?, inspect({payload["type"], key, bad})
      assert observation.malformed_metadata?, inspect({payload["type"], key, bad})
      assert observation.safe_payload == Map.delete(payload, key)
      assert observation.native_id == if(key == "id", do: nil, else: "evt_invented")

      if key == "processed_at",
        do: assert(observation.occurred_at == nil),
        else: assert(DateTime.to_iso8601(observation.occurred_at) == @time)

      assert_diagnosed(malformed, observation.safe_payload)
    end

    for type <- @types do
      payload =
        type
        |> activity()
        |> Map.put("processed_at", "2026-01-01T01:00:00+01:00")

      assert Claude.interpret(payload).malformed_metadata?
      refute Map.has_key?(Claude.interpret(payload).safe_payload, "processed_at")
    end
  end

  test "optional origin hints preserve valid siblings" do
    for type <- @types -- ["session.thread_created"] do
      payload = activity(type)
      assert_projection(payload, payload)

      hinted = Map.put(payload, "session_thread_id", "sthr_origin")
      assert_projection(hinted, hinted)

      for bad <- [nil, "", 1, [], String.duplicate("a", 1025), "bad\0id"] do
        malformed = Map.put(payload, "session_thread_id", bad)
        observation = Claude.interpret(malformed)
        assert observation.supported?
        assert observation.malformed_metadata?
        assert observation.native_id == "evt_invented"
        assert DateTime.to_iso8601(observation.occurred_at) == @time
        assert observation.safe_payload == payload
        assert_diagnosed(malformed, payload)
      end
    end
  end

  test "retained activity fixture produces the frozen dropped artifact" do
    fixture_dir = Path.expand("../../fixtures/evidence", __DIR__)
    retained_bytes = File.read!(Path.join(fixture_dir, "cma_activity_retained_wirev1.json"))
    retained = Jason.decode!(retained_bytes)
    dropped_bytes = File.read!(Path.join(fixture_dir, "cma_activity_drop_wirev1.json"))
    dropped = Jason.decode!(dropped_bytes)
    assert retained_bytes =~ "synthetic-thinking-content-sentinel"
    refute dropped_bytes =~ "sentinel"

    assert {:ok, capture} = Capture.new(Map.put(retained, "diagnostics", []), content: :drop)
    assert Evidence.to_wire(capture) == dropped
    assert {:ok, restored} = Evidence.from_wire(dropped)
    assert Evidence.to_wire(restored) == dropped

    activities =
      Enum.filter(capture.records, &(&1.kind == :native and &1.payload["type"] in @types))

    assert Enum.frequencies_by(activities, & &1.payload["type"]) == %{
             "agent.thinking" => 3,
             "session.thread_created" => 2,
             "agent.thread_message_sent" => 5,
             "agent.thread_message_received" => 2
           }

    for record <- activities do
      raw = Enum.find(retained["records"], &(&1["id"] == record.id))["payload"]
      keys = Enum.uniq(["type", "session_thread_id" | required_keys(raw["type"])])
      assert record.payload == Map.take(raw, keys)
      refute record.validation_issue?
    end
  end

  defp assert_projection(payload, expected) do
    payload =
      Map.merge(payload, %{
        "agent_name" => @private,
        "from_agent_name" => @private,
        "to_agent_name" => @private,
        "name" => @private,
        "content" => [%{"type" => "text", "text" => @private}],
        "parent_thread_id" => @private,
        "workflow_run_id" => @private,
        "unknown" => %{"body" => @private}
      })

    observation = Claude.interpret(payload)
    assert observation.supported?
    refute observation.malformed_metadata?
    assert observation.native_id == "evt_invented"
    assert DateTime.to_iso8601(observation.occurred_at) == @time
    assert observation.safe_payload == expected
    assert Event.classify(payload) == :other

    for kind <- [:claude_session, :claude_thread] do
      dropped = round_trip(payload, kind)
      assert hd(dropped.records).payload == expected
      refute hd(dropped.records).validation_issue?
      refute Enum.any?(dropped.diagnostics, &(&1.code == :unsupported_record))
      refute Jason.encode!(Evidence.to_wire(dropped)) =~ @private

      retained = round_trip(payload, kind, content: :retain)
      assert hd(retained.records).payload == payload
      assert hd(retained.records).content_state == :retained
      assert Jason.encode!(Evidence.to_wire(retained)) =~ @private
    end
  end

  defp assert_diagnosed(payload, expected) do
    for kind <- [:claude_session, :claude_thread] do
      restored = round_trip(payload, kind)
      assert hd(restored.records).payload == expected
      assert Enum.any?(restored.diagnostics, &(&1.code == :unsupported_record))
    end
  end

  defp directions do
    [
      {"agent.thread_message_sent", "to_session_thread_id", "from_session_thread_id"},
      {"agent.thread_message_received", "from_session_thread_id", "to_session_thread_id"}
    ]
  end

  defp required_keys("session.thread_created"), do: ~w(id processed_at session_thread_id)
  defp required_keys("agent.thread_message_sent"), do: ~w(id processed_at to_session_thread_id)

  defp required_keys("agent.thread_message_received"),
    do: ~w(id processed_at from_session_thread_id)

  defp required_keys("agent.thinking"), do: ~w(id processed_at)

  defp event(type), do: %{"type" => type, "id" => "evt_invented", "processed_at" => @time}

  defp activities, do: Enum.map(@types, &activity/1)

  defp activity(type) do
    case required_keys(type) -- ~w(id processed_at) do
      [peer] -> Map.put(event(type), peer, "sthr_peer")
      [] -> event(type)
    end
  end

  defp round_trip(payload, kind, opts \\ []) do
    assert {:ok, capture} =
             Capture.new(
               %{
                 capture_id: "capture_invented",
                 provider: :managed,
                 session_id: "sesn_invented",
                 started_at: @time,
                 ended_at: @time,
                 sources: [
                   %{id: "source_invented", kind: kind, scope: "sesn_invented", status: :complete}
                 ],
                 records: [
                   %{
                     id: "record_invented",
                     source_id: "source_invented",
                     ordinal: 1,
                     observed_at: @time,
                     clock: :wall,
                     kind: :native,
                     payload: payload
                   }
                 ]
               },
               opts
             )

    wire =
      capture
      |> Evidence.to_wire()
      |> Jason.encode!()
      |> Jason.decode!()

    assert {:ok, restored} = Evidence.from_wire(wire)
    restored
  end
end
