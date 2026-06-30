defmodule ReqManagedAgents.Providers.ManagedAgentsTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Providers.ManagedAgents

  defp use_event(id, name, input),
    do: %{"type" => "agent.custom_tool_use", "id" => id, "name" => name, "input" => input}

  defp idle(reason, event_ids \\ []),
    do: %{"type" => "session.status_idle", "stop_reason" => %{"type" => reason, "event_ids" => event_ids}}

  test "normalize/1 emits requested custom_tool_uses in event_ids order on requires_action" do
    events = [use_event("e1", "f", %{"a" => 1}), use_event("e2", "g", %{"b" => 2}), idle("requires_action", ["e2", "e1"])]

    assert ManagedAgents.normalize(events) == %{
             terminal: :requires_action,
             stop_reason: "requires_action",
             custom_tool_uses: [
               %{id: "e2", name: "g", input: %{"b" => 2}},
               %{id: "e1", name: "f", input: %{"a" => 1}}
             ],
             text: ""
           }
  end

  test "normalize/1 maps an end_turn idle to :end_turn with no custom_tool_uses" do
    assert %{terminal: :end_turn, stop_reason: "end_turn", custom_tool_uses: []} =
             ManagedAgents.normalize([idle("end_turn")])
  end

  test "server-side exclusion: a custom_tool_use NOT in event_ids is not surfaced" do
    # e2 is a provider-executed tool the loop ran itself; only e1 is returned to us.
    events = [use_event("e1", "f", %{}), use_event("e2", "server_search", %{}), idle("requires_action", ["e1"])]
    assert [%{id: "e1"}] = ManagedAgents.normalize(events).custom_tool_uses
  end

  test "normalize/1 uses the MOST RECENT idle (multi-turn accumulated events)" do
    events = [
      use_event("e1", "f", %{}),
      idle("requires_action", ["e1"]),
      use_event("e2", "g", %{}),
      idle("requires_action", ["e2"])
    ]

    assert [%{id: "e2", name: "g"}] = ManagedAgents.normalize(events).custom_tool_uses
  end

  test "terminal/1 collapses to the canonical three atoms" do
    assert ManagedAgents.terminal("end_turn") == :end_turn
    assert ManagedAgents.terminal("requires_action") == :requires_action
    assert ManagedAgents.terminal("retries_exhausted") == :terminated
    assert ManagedAgents.terminal("anything_else") == :terminated
    assert ManagedAgents.terminal(nil) == :terminated
  end

  test "normalize/1 maps a terminated/error stream to :terminated" do
    assert %{terminal: :terminated} = ManagedAgents.normalize([%{"type" => "session.status_terminated"}])
    assert %{terminal: :terminated} = ManagedAgents.normalize([%{"type" => "session.error"}])
  end

  test "normalize/1 never crashes on a status_idle with null/absent stop_reason (jido idle)" do
    # latest_status/1 recognizes a status_idle by type alone; a null or typeless
    # stop_reason must NOT raise (the old Event.classify degraded it to :other). The
    # jido creation-time idle is Profile's context-dependent concern, not this provider's;
    # here we conservatively terminate rather than crash or hang.
    assert %{terminal: :terminated, custom_tool_uses: []} =
             ManagedAgents.normalize([%{"type" => "session.status_idle", "stop_reason" => nil}])

    assert %{terminal: :terminated, custom_tool_uses: []} =
             ManagedAgents.normalize([%{"type" => "session.status_idle"}])
  end

  test "normalize/1 keeps :requires_action even when event_ids reference unstashed ids" do
    # The spec's "non-empty iff :requires_action" is the normal case; a requires_action
    # whose event_ids reference ids we never stashed yields an empty custom_tool_uses.
    # The drivers resolve([]) → no-op continue (matching pre-refactor behavior).
    events = [%{"type" => "session.status_idle", "stop_reason" => %{"type" => "requires_action", "event_ids" => ["ghost"]}}]
    assert %{terminal: :requires_action, custom_tool_uses: []} = ManagedAgents.normalize(events)
  end

  test "resume/2 builds user.custom_tool_result events from canonical results" do
    results = [%{tool_use_id: "e1", text: "ok", is_error: false}, %{tool_use_id: "e2", text: "boom", is_error: true}]
    events = ManagedAgents.resume([], results)

    assert [%{"type" => "user.custom_tool_result", "custom_tool_use_id" => "e1", "is_error" => false} = ok, boom] = events
    assert get_in(ok, ["content", Access.at(0), "text"]) == "ok"
    assert boom["is_error"] == true
  end

  test "implements the Provider behaviour" do
    callbacks = ReqManagedAgents.Provider.behaviour_info(:callbacks)
    for cb <- callbacks, do: assert function_exported?(ManagedAgents, elem(cb, 0), elem(cb, 1))
  end
end
