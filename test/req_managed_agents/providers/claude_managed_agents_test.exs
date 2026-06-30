defmodule ReqManagedAgents.Providers.ClaudeManagedAgentsTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Providers.ClaudeManagedAgents, as: ManagedAgents

  defp use_event(id, name, input),
    do: %{"type" => "agent.custom_tool_use", "id" => id, "name" => name, "input" => input}

  defp idle(reason, event_ids \\ []),
    do: %{"type" => "session.status_idle", "stop_reason" => %{"type" => reason, "event_ids" => event_ids}}

  test "normalize/1 emits requested custom_tool_uses in event_ids order on requires_action" do
    events = [use_event("e1", "f", %{"a" => 1}), use_event("e2", "g", %{"b" => 2}), idle("requires_action", ["e2", "e1"])]

    assert ManagedAgents.normalize(events) == %{
             terminal: :requires_action,
             # stop_reason is the provider's raw map, preserved verbatim (not collapsed to a string)
             stop_reason: %{"type" => "requires_action", "event_ids" => ["e2", "e1"]},
             custom_tool_uses: [
               %{id: "e2", name: "g", input: %{"b" => 2}},
               %{id: "e1", name: "f", input: %{"a" => 1}}
             ],
             server_tool_uses: [],
             text: "",
             # Raw events preserved verbatim alongside the normalized view.
             events: events
           }
  end

  test "normalize/1 maps an end_turn idle to :end_turn with no custom_tool_uses" do
    assert %{terminal: :end_turn, stop_reason: %{"type" => "end_turn"}, custom_tool_uses: []} =
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

  # Assistant-text extraction. agent.message shape verified against Anthropic's Managed
  # Agents docs and the biai-platform consumer:
  # %{"type" => "agent.message", "content" => [%{"type" => "text", "text" => ...}]}.
  test "normalize/1 joins text blocks across agent.message events with newlines (matches consumer)" do
    events = [
      %{"type" => "agent.message", "content" => [%{"type" => "text", "text" => "First line."}]},
      %{"type" => "agent.message", "content" => [%{"type" => "text", "text" => "Second line."}]},
      idle("end_turn")
    ]

    assert %{terminal: :end_turn, text: "First line.\nSecond line."} = ManagedAgents.normalize(events)
  end

  test "normalize/1 joins multiple text blocks within one agent.message and skips non-text blocks" do
    events = [
      %{
        "type" => "agent.message",
        "content" => [
          %{"type" => "text", "text" => "para 1"},
          %{"type" => "thinking", "thinking" => "internal"},
          %{"type" => "text", "text" => "para 2"}
        ]
      },
      idle("end_turn")
    ]

    # thinking block skipped (no stray newline); the two text blocks joined with "\n".
    assert %{text: "para 1\npara 2"} = ManagedAgents.normalize(events)
  end

  test "normalize/1 surfaces assistant text alongside a requires_action turn" do
    events = [
      %{"type" => "agent.message", "content" => [%{"type" => "text", "text" => "calling a tool"}]},
      use_event("e1", "lookup", %{"q" => "hi"}),
      idle("requires_action", ["e1"])
    ]

    assert %{terminal: :requires_action, text: "calling a tool", custom_tool_uses: [%{id: "e1"}]} =
             ManagedAgents.normalize(events)
  end

  test "normalize/1 text is \"\" when no agent.message is present" do
    assert %{text: ""} = ManagedAgents.normalize([idle("end_turn")])
  end

  # Server-side tools (agent.tool_use) — observe-only. Shape verified against the
  # biai-platform consumer: %{"type" => "agent.tool_use", "name" => ..., "input" => ...}.
  test "normalize/1 surfaces agent.tool_use as observe-only server_tool_uses (keeping the event id)" do
    events = [
      %{"type" => "agent.tool_use", "id" => "st1", "name" => "web_search", "input" => %{"q" => "weather"}},
      idle("end_turn")
    ]

    assert %{
             terminal: :end_turn,
             server_tool_uses: [%{id: "st1", name: "web_search", input: %{"q" => "weather"}}]
           } = ManagedAgents.normalize(events)
  end

  test "normalize/1 surfaces multiple agent.tool_use events; missing input defaults to %{}" do
    events = [
      %{"type" => "agent.tool_use", "id" => "s1", "name" => "search", "input" => %{"q" => "a"}},
      %{"type" => "agent.tool_use", "id" => "s2", "name" => "now"},
      idle("end_turn")
    ]

    assert %{
             server_tool_uses: [
               %{id: "s1", name: "search", input: %{"q" => "a"}},
               %{id: "s2", name: "now", input: %{}}
             ]
           } = ManagedAgents.normalize(events)
  end

  test "thesis guard: a server-side agent.tool_use never enters custom_tool_uses" do
    # A turn with BOTH a client-side custom tool (return-of-control) and a server-side tool
    # the managed loop ran itself. Only the custom one is actionable; the server one is
    # observe-only and must never be handed to the Handler.
    events = [
      use_event("e1", "lookup", %{"q" => "hi"}),
      %{"type" => "agent.tool_use", "name" => "web_search", "input" => %{"q" => "x"}},
      idle("requires_action", ["e1"])
    ]

    outcome = ManagedAgents.normalize(events)
    assert [%{id: "e1", name: "lookup"}] = outcome.custom_tool_uses
    assert [%{name: "web_search"}] = outcome.server_tool_uses
  end

  test "normalize/1 preserves the raw events verbatim alongside the normalized view" do
    raw = [
      %{"type" => "agent.message", "content" => [%{"type" => "text", "text" => "hi"}]},
      %{"type" => "agent.tool_use", "id" => "s1", "name" => "search", "input" => %{}},
      use_event("e1", "lookup", %{}),
      idle("requires_action", ["e1"])
    ]

    outcome = ManagedAgents.normalize(raw)

    # Normalized convenience views over the wire...
    assert outcome.text == "hi"
    assert [%{name: "search"}] = outcome.server_tool_uses
    assert [%{id: "e1"}] = outcome.custom_tool_uses
    # ...and the raw provider events, untouched, for cross-referencing the provider's docs.
    assert outcome.events == raw
  end

  test "implements the streaming Provider callbacks" do
    Code.ensure_loaded!(ManagedAgents)
    for {f, a} <- [{:mode, 0}, {:open, 2}, {:kickoff_input, 1}, {:user_input, 1},
                   {:resume_input, 2}, {:normalize, 1}, {:push_input, 2}, {:turn_boundary?, 1}] do
      assert function_exported?(ManagedAgents, f, a)
    end
  end

  test "mode/0 is :streaming" do
    assert ManagedAgents.mode() == :streaming
  end

  test "turn_boundary?/1 is true only for session status/terminal/error events" do
    assert ManagedAgents.turn_boundary?(%{"type" => "session.status_idle", "stop_reason" => %{"type" => "end_turn"}})
    assert ManagedAgents.turn_boundary?(%{"type" => "session.status_terminated"})
    assert ManagedAgents.turn_boundary?(%{"type" => "session.error"})
    refute ManagedAgents.turn_boundary?(%{"type" => "agent.message", "content" => []})
    refute ManagedAgents.turn_boundary?(%{"type" => "agent.custom_tool_use", "id" => "e1"})
  end

  test "kickoff_input/1 and user_input/1 build user.message events" do
    assert [%{"type" => "user.message", "content" => [%{"text" => "go"}]}] = ManagedAgents.kickoff_input(prompt: "go")
    assert [%{"type" => "user.message", "content" => [%{"text" => "hi"}]}] = ManagedAgents.user_input("hi")
  end

  test "resume_input/2 builds user.custom_tool_result events (no echo)" do
    results = [%{tool_use_id: "e1", text: "ok", is_error: false}, %{tool_use_id: "e2", text: "boom", is_error: true}]
    assert [ok, boom] = ManagedAgents.resume_input([], results)
    assert ok["type"] == "user.custom_tool_result" and ok["custom_tool_use_id"] == "e1"
    assert get_in(ok, ["content", Access.at(0), "text"]) == "ok"
    assert boom["is_error"] == true
  end
end
