defmodule ReqManagedAgents.Providers.BedrockAgentCoreTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Providers.BedrockAgentCore, as: P

  defp start_block(idx, id, name),
    do: %{"contentBlockStart" => %{"contentBlockIndex" => idx, "start" => %{"toolUse" => %{"toolUseId" => id, "name" => name}}}}

  defp delta(idx, frag),
    do: %{"contentBlockDelta" => %{"contentBlockIndex" => idx, "delta" => %{"toolUse" => %{"input" => frag}}}}

  defp tool_stop, do: %{"messageStop" => %{"stopReason" => "tool_use"}}

  defp conn(invoke_fun),
    do: elem(P.open([harness_arn: "arn", runtime_session_id: String.duplicate("s", 33), invoke_fun: invoke_fun], self()), 1)

  # ── normalize ─────────────────────────────────────────────────────────────────
  test "normalize maps a tool_use turn to canonical custom_tool_uses + :requires_action, preserving raw events" do
    events = [start_block(0, "tu_1", "echo"), delta(0, ~s({"text":"hi"})), tool_stop()]

    assert P.normalize(events) == %{
             terminal: :requires_action,
             stop_reason: "tool_use",
             custom_tool_uses: [%{id: "tu_1", name: "echo", input: %{"text" => "hi"}}],
             server_tool_uses: [],
             text: "",
             events: events
           }
  end

  test "normalize maps a normal stop to :end_turn" do
    events = [%{"contentBlockDelta" => %{"contentBlockIndex" => 0, "delta" => %{"text" => "done."}}},
              %{"messageStop" => %{"stopReason" => "end_turn"}}]
    assert %{terminal: :end_turn, stop_reason: "end_turn", custom_tool_uses: [], text: "done."} = P.normalize(events)
  end

  test "terminal collapses to the canonical three atoms" do
    assert P.terminal("end_turn") == :end_turn
    assert P.terminal("stop_sequence") == :end_turn
    assert P.terminal("tool_use") == :requires_action
    assert P.terminal("max_tokens") == :terminated
    assert P.terminal("anything") == :terminated
  end

  test "MIM-52 regression: a reused contentBlockIndex recovers BOTH distinct tools" do
    events = [start_block(0, "tu_A", "f"), start_block(0, "tu_B", "g"), tool_stop()]
    assert ["tu_A", "tu_B"] = Enum.map(P.normalize(events).custom_tool_uses, & &1.id)
  end

  test "server-side exclusion: unrecognized content never enters custom_tool_uses; server_tool_uses is []" do
    events = [%{"contentBlockStart" => %{"contentBlockIndex" => 0, "start" => %{"someServerTool" => %{"name" => "x"}}}},
              start_block(1, "tu_1", "echo"), delta(1, ~s({})), tool_stop()]
    out = P.normalize(events)
    assert [%{id: "tu_1"}] = out.custom_tool_uses
    assert out.server_tool_uses == []
  end

  # ── invocation ────────────────────────────────────────────────────────────────
  test "mode/0 is :request_response" do
    assert P.mode() == :request_response
  end

  test "kickoff_input/1 and user_input/1 build user messages" do
    assert P.kickoff_input(prompt: "go") == [%{"role" => "user", "content" => [%{"text" => "go"}]}]
    assert P.user_input("hi") == [%{"role" => "user", "content" => [%{"text" => "hi"}]}]
  end

  test "resume_input/2 produces the strict two-message delta" do
    uses = [%{id: "tu_1", name: "echo", input: %{"text" => "hi"}}]
    results = [%{tool_use_id: "tu_1", text: "echoed: hi", is_error: false}]
    assert [%{"role" => "assistant", "content" => [%{"toolUse" => tu}]}, user] = P.resume_input(uses, results)
    assert tu == %{"toolUseId" => "tu_1", "name" => "echo", "input" => %{"text" => "hi"}}
    assert get_in(user, ["content", Access.at(0), "toolResult", "status"]) == "success"
  end

  test "poll_turn/2 returns a turn's events" do
    events = [%{"messageStop" => %{"stopReason" => "end_turn"}}]
    assert {:ok, ^events, _conn} = P.poll_turn(conn(fn _inv -> {:ok, events} end), [])
  end

  test "poll_turn/2 surfaces a __stream_error__ frame as a harness_stream_error" do
    events = [%{"__stream_error__" => %{"type" => "ValidationException", "message" => "boom"}}]
    assert {:error, {:harness_stream_error, "ValidationException", "boom"}} =
             P.poll_turn(conn(fn _inv -> {:ok, events} end), [])
  end

  test "poll_turn/2 retries a truncated turn (no terminal stop_reason) then surfaces it" do
    # First call: truncated (no messageStop). Retry: a clean end_turn.
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    invoke_fun = fn _inv ->
      n = Agent.get_and_update(agent, &{&1, &1 + 1})
      if n == 0, do: {:ok, []}, else: {:ok, [%{"messageStop" => %{"stopReason" => "end_turn"}}]}
    end
    assert {:ok, [%{"messageStop" => _}], _conn} = P.poll_turn(conn(invoke_fun), [])
  end

  test "implements the Provider behaviour callbacks" do
    Code.ensure_loaded!(P)
    for {f, a} <- [{:mode, 0}, {:open, 2}, {:kickoff_input, 1}, {:user_input, 1},
                   {:resume_input, 2}, {:normalize, 1}, {:poll_turn, 2}] do
      assert function_exported?(P, f, a)
    end
  end
end
