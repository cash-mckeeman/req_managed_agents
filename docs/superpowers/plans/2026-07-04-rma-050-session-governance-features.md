# RMA 0.5.0 — Session Governance Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Four session-level additions that all providers benefit from: (a) `turn_guard` — the frozen governance hook (plain data in, plain verdict out); (b) terminal-tool enforcement with bounded re-prompts; (c) `rma.text_delta` normalized text deltas; (d) outcomes — native `user.define_outcome` support on the Claude Managed Agents provider (RMA GH #31), plus `Session.send_event/2`.

**Architecture:** All changes live in the `Session` loop and the two provider modules. `turn_guard` and terminal-tool enforcement hook into `handle_turn/2` (after `accumulate/2`, before the terminal `cond`). Text deltas add one optional `Provider` callback (`text_delta/1`) that `Session` consults wherever it forwards a raw event — synthetic events go to the handler/telemetry only, never into `SessionResult.events`. Outcomes are a kickoff-builder change on the Claude provider gated by a `supports_outcomes?/0` capability callback.

**Tech Stack:** Elixir ~> 1.16, ExUnit, Bypass (already a test dep) for wire-level Claude tests. No new deps.

**Spec:** `docs/superpowers/specs/2026-07-04-mim79-consolidation-architecture-design.md` §4 (0.5.0 row), §7 (outcomes spike). Binding prior art: `mimir-gateway` `docs/planning/2026-07-04-rma-local-provider-and-session-gaps.md` §4; RMA GH issue #31 (implementation-ready design in comments).

## Global Constraints

- **Version control is jj, not git.** Commit with `jj describe -m "<message>" && jj new`. Never `git add/commit/push`. Use `--git` on any `jj diff`/`jj show`.
- **Public-repo hygiene:** internal tracker identifiers (`MIM-…`) never appear in commit messages, code, comments, test names, moduledocs, README, CHANGELOG, or PR titles. The ONLY permitted tracker reference is the PR body's trailing `Closes MIM-…` line. (GitHub issue refs like `Closes #31` are fine — that tracker is public.) Precondition: the public-repo hygiene sweep (`docs/superpowers/plans/2026-07-04-rma-public-repo-hygiene-sweep.md`) has run before this release starts.
- **The `turn_guard` contract is FROZEN by this release** (mimir 0.2.0's `Mimir.Guard` targets it): `fn %{usage: usage_map, turns: n, session_id: id} -> :cont | {:halt, reason} end`, invoked after each turn's `accumulate/2`. The `:usage` value is a **plain map** (`%{input_tokens: n, output_tokens: n, raw: [...]}`), deliberately NOT the `%Usage{}` struct. On halt: notify a `:terminated` `SessionResult`, return `{:error, {:halted, reason}}`.
- **Additive normalization rule:** `rma.text_delta` is emitted alongside, never instead of, the raw event; it is never stored in `SessionResult.events` (raw preservation).
- **Outcome terminal semantics** (GH #31): only `session.status_idle` with `stop_reason.type` of `end_turn` / `satisfied` / `max_iterations_reached` / `failed` is terminal. `span.outcome_evaluation_end` with `needs_revision` is NOT terminal — tested explicitly.
- `:outcome` and `:prompt` are mutually exclusive on kickoff — outcome wins.
- `{:error, :outcome_unsupported}` when `:outcome` is passed to a provider without native outcome support (Bedrock AgentCore today).
- Directive strings relocated from biai-managed-agents keep the biai wording verbatim (eval-gate continuity for the SP7 migration) — exact text is embedded in the tasks below.
- Release discipline: version `0.5.0` in `mix.exs` (bump from `0.4.1`), dated CHANGELOG entry. Tasks are grouped one-per-concern so the executor can ship 1 PR per concern (position doc's release note) or one release PR.
- Full suite green: `mix test`.

---

### Task 1: `turn_guard` — the between-turn governance hook

**Files:**
- Modify: `lib/req_managed_agents/session.ex` (moduledoc opts list ~line 22; `init/1` state map ~line 94; `handle_turn/2` ~lines 291–309)
- Test: `test/req_managed_agents/session_turn_guard_test.exs` (create)

**Interfaces:**
- Consumes: existing `handle_turn/2` / `accumulate/2` / `session_result/3` / `notify/2` / `stop_error/2` internals.
- Produces: Session opt `turn_guard: (map() -> :cont | {:halt, term()})`. The guard payload is `%{usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer(), raw: [map()]}, turns: pos_integer(), session_id: String.t() | nil}`. Task 2 restructures around the same `continue_turn/2` split introduced here.

- [ ] **Step 1: Write the failing tests**

Create `test/req_managed_agents/session_turn_guard_test.exs`:

```elixir
defmodule ReqManagedAgents.SessionTurnGuardTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.FakeProviders.RequestResponse
  alias ReqManagedAgents.Session
  alias ReqManagedAgents.SessionResult

  @tool_turn [
    %{"type" => "tool", "id" => "t1", "name" => "echo", "input" => %{}},
    %{"type" => "stop", "terminal" => :requires_action}
  ]
  @end_turn [%{"type" => "stop", "terminal" => :end_turn}]

  defp ok_handler, do: fn _n, _i, _c -> {:ok, "x"} end

  test "guard returning :cont leaves the run unaffected" do
    assert {:ok, %SessionResult{terminal: :end_turn, turns: 2}} =
             Session.run(RequestResponse,
               handler: ok_handler(),
               turns: [@tool_turn, @end_turn],
               turn_guard: fn _ -> :cont end
             )
  end

  test "guard halt terminates: {:error, {:halted, reason}} + :terminated notify" do
    assert {:error, {:halted, {:budget_exceeded, 2}}} =
             Session.run(RequestResponse,
               handler: ok_handler(),
               notify: self(),
               turns: [@tool_turn, @end_turn],
               turn_guard: fn %{turns: n} ->
                 if n >= 2, do: {:halt, {:budget_exceeded, n}}, else: :cont
               end
             )

    assert_received {:managed_agents_session, %SessionResult{terminal: :terminated, turns: 2}}
  end

  test "guard payload is plain data: usage map (not struct), turns, session_id" do
    test = self()

    {:ok, _} =
      Session.run(RequestResponse,
        handler: ok_handler(),
        turns: [@end_turn],
        turn_guard: fn payload ->
          send(test, {:guard_saw, payload})
          :cont
        end
      )

    assert_received {:guard_saw, payload}
    assert %{usage: usage, turns: 1, session_id: _} = payload
    refute is_struct(usage)
    assert %{input_tokens: 1, output_tokens: 1, raw: [_]} = usage
  end

  test "invalid turn_guard is rejected at start" do
    assert {:error, {:invalid_turn_guard, :nope}} =
             Session.run(RequestResponse, handler: ok_handler(), turns: [], turn_guard: :nope)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/req_managed_agents/session_turn_guard_test.exs`
Expected: the `:cont` test passes vacuously (unknown opt ignored today — that is the bug); the halt, payload, and validation tests FAIL.

- [ ] **Step 3: Implement in `Session`**

**(a)** `init/1` — validate and store the guard. At the top of `init/1`, before `provider.open/2`:

```elixir
  def init({provider, opts}) do
    # Trap exits so a crash in the linked stream-consumer / poll-turn Task arrives as {:EXIT,…}
    # (driving reconnect or a surfaced error) instead of killing this process and its caller.
    Process.flag(:trap_exit, true)

    case validate_opts(provider, opts) do
      :ok -> open_session(provider, opts)
      {:error, reason} -> {:stop, reason}
    end
  end

  # The one home for start-time contract checks — later tasks add a clause here,
  # not another chain in init/1.
  defp validate_opts(_provider, opts) do
    cond do
      not valid_turn_guard?(opts[:turn_guard]) ->
        {:error, {:invalid_turn_guard, opts[:turn_guard]}}

      true ->
        :ok
    end
  end

  defp valid_turn_guard?(nil), do: true
  defp valid_turn_guard?(guard), do: is_function(guard, 1)

  # The former init/1 body, from `case provider.open(opts, self()) do` down, moves here
  # verbatim — state map and {:continue, …} tuple unchanged (plus the new :turn_guard key).
  defp open_session(provider, opts) do
    case provider.open(opts, self()) do
      ...existing body unchanged...
    end
  end
```

Add to the state map: `turn_guard: opts[:turn_guard],`.

**(b)** `handle_turn/2` — invoke the guard after `accumulate/2`; move the existing `cond` into `continue_turn/2` (Task 2 extends that `cond`):

```elixir
  defp handle_turn(s, turn_events) do
    s = %{s | events: s.events ++ turn_events, turns: s.turns + 1}
    tr = s.provider.normalize(turn_events)
    s = accumulate(s, tr)
    emit_tool_use_telemetry(s, tr.custom_tool_uses)

    # The frozen governance hook: plain data in, plain verdict out. Hosts compose
    # policy here (budget caps, grant checks); this library ships only the mechanism.
    case run_turn_guard(s) do
      :cont ->
        continue_turn(s, tr)

      {:halt, reason} ->
        notify(s, session_result(s, tr, :terminated))
        stop_error(s, {:halted, reason})
    end
  end

  defp run_turn_guard(%{turn_guard: nil}), do: :cont

  defp run_turn_guard(s) do
    s.turn_guard.(%{
      usage: Map.from_struct(s.usage),
      turns: s.turns,
      session_id: s.info.session_id
    })
  end

  defp continue_turn(s, tr) do
    cond do
      s.turns > s.max_turns ->
        notify(s, session_result(s, tr, :terminated))
        stop_error(s, {:max_turns_exceeded, s.max_turns})

      tr.terminal == :requires_action ->
        results = run_tools(tr.custom_tool_uses, s)
        drive(s, s.provider.resume_input(tr.custom_tool_uses, results))

      true ->
        finish(s, tr)
    end
  end
```

**(c)** Moduledoc — add to the optional-opts sentence: `` `:turn_guard` (a 1-arity fun invoked after each turn's usage accumulation with `%{usage: map, turns: n, session_id: id}`, returning `:cont` or `{:halt, reason}`; on halt the run stops with `{:error, {:halted, reason}}` and a `:terminated` result is notified — usage/turns accumulate within the current request, the same scope as `:max_turns`) ``.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/req_managed_agents/session_turn_guard_test.exs test/req_managed_agents/session_loop_test.exs`
Expected: all PASS (loop tests confirm the `continue_turn` extraction changed nothing).

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(session): turn_guard — frozen between-turn governance hook

Invoked after each turn's accumulate with plain data
(%{usage: map, turns: n, session_id: id}); :cont | {:halt, reason}.
On halt: :terminated SessionResult notified, {:error, {:halted, reason}}.
RMA ships the mechanism; hosts (Mimir.Guard, StepRunner) own the policy." && jj new
```

---

### Task 2: Terminal-tool enforcement (`require_terminal_tool` + `max_reprompts`)

**Files:**
- Modify: `lib/req_managed_agents/session.ex` (moduledoc; `init/1`; `reset_acc/1`; `continue_turn/2` from Task 1)
- Test: `test/req_managed_agents/session_terminal_tool_test.exs` (create)

**Interfaces:**
- Consumes: Task 1's `continue_turn/2` split; existing `drive/2`, `finish/2`, `s.custom_tool_uses` accumulator; `provider.user_input/1`.
- Produces: Session opts `require_terminal_tool: boolean()` (default `false`), `terminal_tool: String.t()` (required when enforcement is on), `max_reprompts: non_neg_integer()` (default `2`). Exhausted re-prompts finish with `stop_reason: :no_terminal_tool`. `TurnResult`/`SessionResult` `stop_reason` typespec widens to `String.t() | map() | atom() | nil`.

- [ ] **Step 1: Write the failing tests**

Create `test/req_managed_agents/session_terminal_tool_test.exs`. It uses a scripted provider that records every input it is driven with, so re-prompts are observable:

```elixir
defmodule ReqManagedAgents.SessionTerminalToolTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Session
  alias ReqManagedAgents.{SessionResult, ToolUse, TurnResult, Usage}

  # :request_response provider: pops scripted turns, reports every input to the test.
  defmodule Recording do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, _sub), do: {:ok, %{turns: opts[:turns] || [], test_pid: opts[:test_pid]}}
    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}
    @impl true
    def poll_turn(%{turns: turns, test_pid: t} = c, input) do
      send(t, {:polled, input})

      case turns do
        [turn | rest] -> {:ok, turn, %{c | turns: rest}}
        [] -> {:ok, [%{"type" => "stop", "terminal" => :end_turn}], c}
      end
    end

    @impl true
    def normalize(events) do
      customs =
        for %{"type" => "tool"} = e <- events,
            do: %ToolUse{id: e["id"], name: e["name"], input: e["input"] || %{}}

      terminal =
        Enum.find_value(events, :terminated, fn
          %{"type" => "stop", "terminal" => t} -> t
          _ -> nil
        end)

      %TurnResult{
        terminal: terminal,
        stop_reason: to_string(terminal),
        custom_tool_uses: customs,
        usage: %Usage{input_tokens: 1, output_tokens: 1, raw: [%{}]},
        events: events
      }
    end
  end

  @end_turn [%{"type" => "stop", "terminal" => :end_turn}]
  @submit_turn [
    %{"type" => "tool", "id" => "s1", "name" => "submit_answer", "input" => %{}},
    %{"type" => "stop", "terminal" => :requires_action}
  ]

  @reprompt "You returned a response without calling submit_answer. You MUST call " <>
              "submit_answer now to finish — produce the result via submit_answer."

  defp run(turns, opts) do
    Session.run(
      Recording,
      [
        handler: fn _n, _i, _c -> {:ok, "ok"} end,
        test_pid: self(),
        turns: turns,
        require_terminal_tool: true,
        terminal_tool: "submit_answer"
      ] ++ opts
    )
  end

  test "end_turn without the terminal tool re-prompts, then finishes :no_terminal_tool" do
    assert {:ok, %SessionResult{terminal: :end_turn, stop_reason: :no_terminal_tool, turns: 3}} =
             run([@end_turn, @end_turn, @end_turn], [])

    assert_received {:polled, :kickoff}
    assert_received {:polled, {:user, @reprompt}}
    assert_received {:polled, {:user, @reprompt}}
    refute_received {:polled, _}
  end

  test "a re-prompt that produces the terminal tool finishes normally" do
    assert {:ok, %SessionResult{terminal: :end_turn, stop_reason: "end_turn", turns: 3}} =
             run([@end_turn, @submit_turn, @end_turn], [])

    assert_received {:polled, :kickoff}
    assert_received {:polled, {:user, @reprompt}}
    assert_received {:polled, {:resume, [_]}}
  end

  test "terminal tool called during the run — no re-prompt" do
    assert {:ok, %SessionResult{terminal: :end_turn, stop_reason: "end_turn", turns: 2}} =
             run([@submit_turn, @end_turn], [])

    refute_received {:polled, {:user, _}}
  end

  test "max_reprompts: 0 finishes :no_terminal_tool immediately" do
    assert {:ok, %SessionResult{stop_reason: :no_terminal_tool, turns: 1}} =
             run([@end_turn], max_reprompts: 0)
  end

  test "require_terminal_tool without terminal_tool is rejected at start" do
    assert {:error, {:invalid_opts, :terminal_tool_required}} =
             Session.run(Recording,
               handler: fn _, _, _ -> {:ok, ""} end,
               test_pid: self(),
               turns: [],
               require_terminal_tool: true
             )
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/req_managed_agents/session_terminal_tool_test.exs`
Expected: FAIL — today the opts are ignored, so runs finish at turn 1 with `stop_reason: "end_turn"` and the validation test gets `{:ok, _}`.

- [ ] **Step 3: Implement in `Session`**

**(a)** Start-time validation — one new clause in Task 1's `validate_opts/2`, above `true ->`:

```elixir
      opts[:require_terminal_tool] && not is_binary(opts[:terminal_tool]) ->
        {:error, {:invalid_opts, :terminal_tool_required}}
```

**(b)** State (in the state map inside `open_session/2`). One field carries the whole feature switch: `nil` means enforcement off, the tool name means on — no separate boolean to keep in sync:

```elixir
          enforced_terminal_tool: if(opts[:require_terminal_tool], do: opts[:terminal_tool]),
          max_reprompts: opts[:max_reprompts] || 2,
          reprompts_left: opts[:max_reprompts] || 2,
```

**(c)** `reset_acc/1` — a follow-up message is a fresh request, so the re-prompt budget resets too:

```elixir
  defp reset_acc(s),
    do: %{
      s
      | events: [],
        custom_tool_uses: [],
        server_tool_uses: [],
        reprompts_left: s.max_reprompts,
        usage: %Usage{input_tokens: 0, output_tokens: 0, raw: []}
    }
```

**(d)** `continue_turn/2` — two clauses between `:requires_action` and the final `true`:

```elixir
  defp continue_turn(s, tr) do
    cond do
      s.turns > s.max_turns ->
        notify(s, session_result(s, tr, :terminated))
        stop_error(s, {:max_turns_exceeded, s.max_turns})

      tr.terminal == :requires_action ->
        results = run_tools(tr.custom_tool_uses, s)
        drive(s, s.provider.resume_input(tr.custom_tool_uses, results))

      # Terminal-tool enforcement: an :end_turn that never called the required tool
      # re-drives with a re-prompt; re-prompt turns count against :max_turns.
      tr.terminal == :end_turn and missing_terminal_tool?(s) and s.reprompts_left > 0 ->
        input = s.provider.user_input(terminal_reprompt(s.enforced_terminal_tool))
        drive(%{s | reprompts_left: s.reprompts_left - 1}, input)

      tr.terminal == :end_turn and missing_terminal_tool?(s) ->
        finish(s, %{tr | stop_reason: :no_terminal_tool})

      true ->
        finish(s, tr)
    end
  end

  defp missing_terminal_tool?(%{enforced_terminal_tool: nil}), do: false

  defp missing_terminal_tool?(%{enforced_terminal_tool: tool} = s),
    do: not Enum.any?(s.custom_tool_uses, &(&1.name == tool))

  # Wording relocated verbatim from biai-managed-agents' Core.Runner.Directives
  # (eval-gate continuity for consumers migrating off that loop).
  defp terminal_reprompt(terminal_tool),
    do:
      "You returned a response without calling #{terminal_tool}. You MUST call " <>
        "#{terminal_tool} now to finish — produce the result via #{terminal_tool}."
```

**(e)** Widen the `stop_reason` typespecs — in `lib/req_managed_agents/turn_result.ex` and `lib/req_managed_agents/session_result.ex` change:

```elixir
          stop_reason: String.t() | map() | atom() | nil,
```

**(f)** Moduledoc — add to the optional-opts sentence: `` `:require_terminal_tool` + `:terminal_tool` + `:max_reprompts` (default 2): an `:end_turn` that never called `terminal_tool` is re-driven with a re-prompt; exhausted re-prompts finish with `stop_reason: :no_terminal_tool`. Re-prompt turns count against `:max_turns` ``.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/req_managed_agents/session_terminal_tool_test.exs test/req_managed_agents/session_turn_guard_test.exs test/req_managed_agents/session_loop_test.exs`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(session): terminal-tool enforcement — require_terminal_tool + max_reprompts

An :end_turn that never called the required terminal tool re-drives via
user_input with a re-prompt (biai Directives wording, verbatim); exhausted
re-prompts finish with stop_reason: :no_terminal_tool. Generalizes the
guard biai's self-managed loop enforced to every provider." && jj new
```

---

### Task 3: `rma.text_delta` — normalized text deltas (additive)

**Files:**
- Modify: `lib/req_managed_agents/provider.ex` (new optional callback), `lib/req_managed_agents/session.ex` (delta forwarding), `lib/req_managed_agents/providers/claude_managed_agents.ex`, `lib/req_managed_agents/providers/bedrock_agent_core.ex`
- Test: `test/req_managed_agents/session_text_delta_test.exs` (create); additions to `test/req_managed_agents/providers/claude_managed_agents_test.exs` and `test/req_managed_agents/providers/bedrock_agent_core_test.exs`

**Interfaces:**
- Consumes: `forward_raw/2` call sites in `Session` (streaming `{:event, ev}` handler, `{:provider_event, ev}` handler, batch forward in `{:turn, {:ok, …}}`).
- Produces: optional `Provider` callback `text_delta(event()) :: String.t() | nil`; the documented synthetic event `%{"type" => "rma.text_delta", "text" => chunk}` delivered through `handle_event`, never stored in `SessionResult.events`. The 0.6.0 Local provider implements the same callback.

- [ ] **Step 1: Write the failing tests**

Create `test/req_managed_agents/session_text_delta_test.exs`:

```elixir
defmodule ReqManagedAgents.SessionTextDeltaTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Session

  # Handler module (fn handlers don't receive handle_event); context carries the test pid.
  defmodule Recorder do
    @behaviour ReqManagedAgents.Handler
    @impl true
    def handle_tool_call(_name, _input, _ctx), do: {:ok, "ok"}
    @impl true
    def handle_event(ev, test_pid, _info), do: send(test_pid, {:handler_event, ev})
  end

  defmodule DeltaProvider do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(_opts, _sub), do: {:ok, %{}}
    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}
    @impl true
    def poll_turn(conn, _input) do
      {:ok, [%{"type" => "say", "text" => "hello"}, %{"type" => "stop"}], conn}
    end

    @impl true
    def normalize(events) do
      %ReqManagedAgents.TurnResult{terminal: :end_turn, stop_reason: "end_turn", events: events}
    end

    @impl true
    def text_delta(%{"type" => "say", "text" => t}), do: t
    def text_delta(_), do: nil
  end

  test "synthetic rma.text_delta follows the raw event to the handler, never into events" do
    assert {:ok, result} =
             Session.run(DeltaProvider, handler: Recorder, context: self())

    assert_received {:handler_event, %{"type" => "say", "text" => "hello"}}
    assert_received {:handler_event, %{"type" => "rma.text_delta", "text" => "hello"}}
    assert_received {:handler_event, %{"type" => "stop"}}
    refute Enum.any?(result.events, &(&1["type"] == "rma.text_delta"))
  end
end
```

Add to `test/req_managed_agents/providers/claude_managed_agents_test.exs`:

```elixir
  describe "text_delta/1" do
    test "maps agent.message text blocks to a chunk" do
      ev = %{
        "type" => "agent.message",
        "content" => [%{"type" => "text", "text" => "hi "}, %{"type" => "text", "text" => "there"}]
      }

      assert ReqManagedAgents.Providers.ClaudeManagedAgents.text_delta(ev) == "hi there"
    end

    test "non-message and empty-text events yield nil" do
      assert ReqManagedAgents.Providers.ClaudeManagedAgents.text_delta(%{"type" => "session.status_idle"}) == nil

      assert ReqManagedAgents.Providers.ClaudeManagedAgents.text_delta(%{
               "type" => "agent.message",
               "content" => [%{"type" => "image"}]
             }) == nil
    end
  end
```

Add to `test/req_managed_agents/providers/bedrock_agent_core_test.exs`:

```elixir
  describe "text_delta/1" do
    test "maps contentBlockDelta text to a chunk" do
      ev = %{"contentBlockDelta" => %{"contentBlockIndex" => 0, "delta" => %{"text" => "chunk"}}}
      assert ReqManagedAgents.Providers.BedrockAgentCore.text_delta(ev) == "chunk"
    end

    test "toolUse deltas and other envelopes yield nil" do
      assert ReqManagedAgents.Providers.BedrockAgentCore.text_delta(%{
               "contentBlockDelta" => %{"delta" => %{"toolUse" => %{"input" => "{}"}}}
             }) == nil

      assert ReqManagedAgents.Providers.BedrockAgentCore.text_delta(%{"messageStop" => %{}}) == nil
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/req_managed_agents/session_text_delta_test.exs test/req_managed_agents/providers/`
Expected: FAIL — `text_delta/1` undefined on both providers; the session test sees no `rma.text_delta` handler event.

- [ ] **Step 3: Add the optional callback to `Provider`**

In `lib/req_managed_agents/provider.ex`, after the `reconnect/3` callback:

```elixir
  @doc """
  Optional — map ONE raw event to a normalized text chunk, or `nil`.

  When implemented, the `Session` emits `%{"type" => "rma.text_delta", "text" => chunk}`
  through `handle_event` immediately after forwarding the raw event (additive
  normalization: alongside, never instead of, the raw event; never stored in
  `SessionResult.events`). Chunk granularity is whatever the provider's wire exposes —
  true streaming deltas on AgentCore (`contentBlockDelta`), whole message blocks on
  Claude Managed Agents (`agent.message`).
  """
  @callback text_delta(event()) :: String.t() | nil
```

And extend the optional list:

```elixir
  @optional_callbacks poll_turn: 2,
                      push_input: 2,
                      turn_boundary?: 1,
                      reconnect: 3,
                      teardown: 2,
                      text_delta: 1
```

- [ ] **Step 4: Implement Session forwarding**

In `lib/req_managed_agents/session.ex`:

**(a)** Resolve the capability once, in `init/1`'s state map (after `provider:`):

```elixir
          delta?: Code.ensure_loaded?(provider) and function_exported?(provider, :text_delta, 1),
```

**(b)** Add the wrapper next to `forward_raw/2`:

```elixir
  # Additive normalization: the synthetic delta follows the raw event through the same
  # handler path and is never accumulated into events (raw preservation).
  defp forward_with_delta(%{delta?: false} = s, ev), do: forward_raw(s, ev)

  defp forward_with_delta(s, ev) do
    forward_raw(s, ev)

    case s.provider.text_delta(ev) do
      chunk when is_binary(chunk) and chunk != "" ->
        forward_raw(s, %{"type" => "rma.text_delta", "text" => chunk})

      _ ->
        :ok
    end
  end
```

**(c)** Swap the three raw-forward call sites to `forward_with_delta`:
- streaming event handler (`handle_info({:managed_agents, ref, {:event, ev}}, …)`): `forward_raw(s, ev)` → `forward_with_delta(s, ev)`
- `handle_info({:provider_event, ev}, s)`: `forward_raw(s, ev)` → `forward_with_delta(s, ev)`
- batch path in `handle_info({:turn, {:ok, events, conn}}, s)`: `Enum.each(events, &forward_raw(s, &1))` → `Enum.each(events, &forward_with_delta(s, &1))`

- [ ] **Step 5: Implement the two provider mappings**

`lib/req_managed_agents/providers/claude_managed_agents.ex` (near `normalize/1`):

```elixir
  @impl true
  def text_delta(%{"type" => "agent.message", "content" => blocks}) when is_list(blocks) do
    case for(%{"type" => "text", "text" => t} <- blocks, is_binary(t), do: t) do
      [] -> nil
      texts -> Enum.join(texts)
    end
  end

  def text_delta(_), do: nil
```

`lib/req_managed_agents/providers/bedrock_agent_core.ex` (near `normalize/1`):

```elixir
  @impl true
  def text_delta(%{"contentBlockDelta" => %{"delta" => %{"text" => t}}}) when is_binary(t), do: t
  def text_delta(_), do: nil
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/req_managed_agents/session_text_delta_test.exs test/req_managed_agents/providers/ test/req_managed_agents/session_live_events_test.exs`
Expected: all PASS (live-events tests confirm raw forwarding is unchanged for providers without `text_delta/1`).

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(providers): rma.text_delta — normalized text deltas, additive

Optional Provider callback text_delta/1; Session emits the documented
synthetic %{\"type\" => \"rma.text_delta\"} through handle_event alongside
(never instead of) the raw event, never into SessionResult.events.
Consumer: fpanda chat UX (MIM-62)." && jj new
```

---

### Task 4: Outcomes — `Event.define_outcome/3`, `:outcome` kickoff, capability gate, terminal semantics

**Files:**
- Modify: `lib/req_managed_agents/event.ex`, `lib/req_managed_agents/providers/claude_managed_agents.ex`, `lib/req_managed_agents/provider.ex` (optional `supports_outcomes?/0`), `lib/req_managed_agents/session.ex` (gate in `init/1`, moduledoc)
- Test: `test/req_managed_agents/event_test.exs` (add), `test/req_managed_agents/providers/claude_managed_agents_test.exs` (add), `test/req_managed_agents/session_outcome_test.exs` (create — Bypass wire-level loop test)

**Interfaces:**
- Consumes: `Event` builder idiom; `kickoff_input/1` already receives the full Session opts; `SSEFixtures.wire/1` + Bypass idiom from `test/req_managed_agents/run_to_completion_test.exs`.
- Produces: `Event.define_outcome(description :: String.t(), rubric_md :: String.t(), opts :: keyword()) :: event()`; Session opt `outcome: %{description: String.t(), rubric: String.t(), max_iterations: pos_integer() | nil}`; optional `Provider` callback `supports_outcomes?() :: boolean()`; `{:error, :outcome_unsupported}` from `Session.run/2` on non-supporting providers; Claude terminal mapping for `satisfied` / `max_iterations_reached` / `failed`.

- [ ] **Step 1: Write the failing unit tests**

Add to `test/req_managed_agents/event_test.exs`:

```elixir
  describe "define_outcome/3" do
    test "builds the wire event with a text rubric" do
      assert ReqManagedAgents.Event.define_outcome("ship it", "- compiles\n- tests pass") == %{
               "type" => "user.define_outcome",
               "description" => "ship it",
               "rubric" => %{"type" => "text", "content" => "- compiles\n- tests pass"}
             }
    end

    test "max_iterations is included only when given" do
      assert %{"max_iterations" => 5} =
               ReqManagedAgents.Event.define_outcome("d", "r", max_iterations: 5)

      refute Map.has_key?(ReqManagedAgents.Event.define_outcome("d", "r"), "max_iterations")
    end
  end

  describe "classify/1 outcome stop reasons" do
    test "satisfied and max_iterations_reached classify as :end_turn; failed as :terminated" do
      idle = fn reason ->
        %{"type" => "session.status_idle", "stop_reason" => %{"type" => reason}}
      end

      assert ReqManagedAgents.Event.classify(idle.("satisfied")) == :end_turn
      assert ReqManagedAgents.Event.classify(idle.("max_iterations_reached")) == :end_turn
      assert ReqManagedAgents.Event.classify(idle.("failed")) == :terminated
    end
  end
```

Add to `test/req_managed_agents/providers/claude_managed_agents_test.exs` (alias the module as in the existing file):

```elixir
  describe "outcomes" do
    test "kickoff_input with :outcome emits user.define_outcome (outcome wins over :prompt)" do
      assert [%{"type" => "user.define_outcome", "description" => "d", "max_iterations" => 3}] =
               ReqManagedAgents.Providers.ClaudeManagedAgents.kickoff_input(
                 prompt: "ignored",
                 outcome: %{description: "d", rubric: "- r", max_iterations: 3}
               )
    end

    test "kickoff_input without :outcome keeps the user.message kickoff" do
      assert [%{"type" => "user.message"}] =
               ReqManagedAgents.Providers.ClaudeManagedAgents.kickoff_input(prompt: "hi")
    end

    test "supports_outcomes?" do
      assert ReqManagedAgents.Providers.ClaudeManagedAgents.supports_outcomes?()
    end

    test "outcome stop reasons: satisfied/max_iterations_reached are :end_turn, failed is :terminated" do
      assert ReqManagedAgents.Providers.ClaudeManagedAgents.terminal("satisfied") == :end_turn

      assert ReqManagedAgents.Providers.ClaudeManagedAgents.terminal("max_iterations_reached") ==
               :end_turn

      assert ReqManagedAgents.Providers.ClaudeManagedAgents.terminal("failed") == :terminated
    end

    test "span.outcome_evaluation_end is NOT a turn boundary (needs_revision keeps running)" do
      refute ReqManagedAgents.Providers.ClaudeManagedAgents.turn_boundary?(%{
               "type" => "span.outcome_evaluation_end",
               "verdict" => "needs_revision"
             })
    end
  end
```

- [ ] **Step 2: Write the failing loop test (wire level)**

Create `test/req_managed_agents/session_outcome_test.exs` — a Bypass-backed run proving: outcome kickoff POSTs `user.define_outcome`; a `needs_revision` evaluation event does not end the run; the `satisfied` idle does; unsupported providers reject at start.

```elixir
defmodule ReqManagedAgents.SessionOutcomeTest do
  use ExUnit.Case
  alias ReqManagedAgents.{Client, Session}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents
  import ReqManagedAgents.SSEFixtures

  setup do
    bypass = Bypass.open()
    client = Client.new(api_key: "sk", base_url: "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass, client: client}
  end

  test "outcome kickoff → needs_revision is not terminal → satisfied finishes", %{
    bypass: bypass,
    client: client
  } do
    test = self()

    Bypass.expect_once(bypass, "POST", "/v1/sessions", fn conn ->
      Req.Test.json(conn, %{"id" => "s1"})
    end)

    Bypass.expect_once(bypass, "GET", "/v1/sessions/s1/events/stream", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          wire([
            %{"type" => "span.outcome_evaluation_end", "verdict" => "needs_revision"},
            %{"type" => "agent.message", "content" => [%{"type" => "text", "text" => "v2"}]},
            %{"type" => "session.status_idle", "stop_reason" => %{"type" => "satisfied"}}
          ])
        )

      conn
    end)

    Bypass.expect(bypass, "POST", "/v1/sessions/s1/events", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posted_events, Jason.decode!(body)})
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert {:ok, result} =
             Session.run(ClaudeManagedAgents,
               client: client,
               handler: fn _n, _i, _c -> {:ok, ""} end,
               agent_id: "ag",
               environment_id: "env",
               outcome: %{description: "do the thing", rubric: "- done", max_iterations: 2},
               timeout: 5_000
             )

    # Terminal only at status_idle satisfied — one turn, not two.
    assert result.terminal == :end_turn
    assert result.stop_reason == %{"type" => "satisfied"}
    assert result.turns == 1

    # The kickoff POST carried the define_outcome event, not a user.message.
    # (Client.send_events/3 posts %{events: events} — see lib/req_managed_agents/client.ex:141.)
    assert_received {:posted_events, %{"events" => kicked}}

    assert Enum.any?(kicked, fn e ->
             e["type"] == "user.define_outcome" and e["max_iterations"] == 2
           end)
  end

  test "outcome on a non-supporting provider is rejected at start" do
    assert {:error, :outcome_unsupported} =
             Session.run(ReqManagedAgents.FakeProviders.RequestResponse,
               handler: fn _, _, _ -> {:ok, ""} end,
               turns: [],
               outcome: %{description: "d", rubric: "r"}
             )
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/req_managed_agents/event_test.exs test/req_managed_agents/providers/claude_managed_agents_test.exs test/req_managed_agents/session_outcome_test.exs`
Expected: FAIL — `define_outcome/3` and `supports_outcomes?/0` undefined; `terminal("satisfied")` currently `:terminated`; the loop test kickoff POSTs a `user.message`.

- [ ] **Step 4: Implement**

**(a)** `lib/req_managed_agents/event.ex` — the builder (GH #31 comment design, verbatim):

```elixir
  @doc "Build a `user.define_outcome` event. `rubric_md` is inline markdown criteria."
  @spec define_outcome(String.t(), String.t(), keyword()) :: event()
  def define_outcome(description, rubric_md, opts \\ [])
      when is_binary(description) and is_binary(rubric_md) do
    base = %{
      "type" => "user.define_outcome",
      "description" => description,
      "rubric" => %{"type" => "text", "content" => rubric_md}
    }

    case Keyword.fetch(opts, :max_iterations) do
      {:ok, n} -> Map.put(base, "max_iterations", n)
      :error -> base
    end
  end
```

And the `classify/1` outcome reasons — extend the inner `case` in the `session.status_idle` clause:

```elixir
    case reason do
      "end_turn" -> :end_turn
      "requires_action" -> :requires_action
      "retries_exhausted" -> :retries_exhausted
      "satisfied" -> :end_turn
      "max_iterations_reached" -> :end_turn
      "failed" -> :terminated
      _ -> :unknown_idle
    end
```

**(b)** `lib/req_managed_agents/providers/claude_managed_agents.ex`:

```elixir
  @impl true
  def kickoff_input(opts) do
    case opts[:outcome] do
      %{description: d, rubric: r} = o ->
        [Event.define_outcome(d, r, max_iterations: o[:max_iterations])]

      nil ->
        [Event.user_message(opts[:prompt] || "Begin.")]
    end
  end

  @impl true
  def supports_outcomes?, do: true
```

And the terminal mapping (`stop_reason` stays verbatim on the result, so consumers can distinguish `satisfied` from `max_iterations_reached`):

```elixir
  @doc false
  def terminal("end_turn"), do: :end_turn
  def terminal("requires_action"), do: :requires_action
  # Outcome sessions (user.define_outcome): the server-side grade→revise loop resolves to one
  # of these at status_idle. satisfied / max_iterations_reached complete the run; failed doesn't.
  def terminal("satisfied"), do: :end_turn
  def terminal("max_iterations_reached"), do: :end_turn
  def terminal("failed"), do: :terminated
  def terminal(_other), do: :terminated
```

**(c)** `lib/req_managed_agents/provider.ex` — the capability callback:

```elixir
  @doc "Optional — true when the provider natively honors the `:outcome` kickoff (`user.define_outcome`)."
  @callback supports_outcomes?() :: boolean()
```

Add `supports_outcomes?: 0` to `@optional_callbacks`.

**(d)** `lib/req_managed_agents/session.ex` — one new clause in `validate_opts/2`, above `true ->`:

```elixir
      # AgentCore has no in-session outcome equivalent (Evaluations is trace-level,
      # out-of-session); fail at start rather than silently kicking off a user.message.
      opts[:outcome] != nil and not outcomes_supported?(provider) ->
        {:error, :outcome_unsupported}
```

(the clause makes `validate_opts/2` use its `provider` argument — drop the `_` prefix), plus the helper:

```elixir
  defp outcomes_supported?(provider) do
    Code.ensure_loaded?(provider) and function_exported?(provider, :supports_outcomes?, 0) and
      provider.supports_outcomes?()
  end
```

Moduledoc: add `:outcome` to the optional opts — `` `:outcome` (`%{description:, rubric:, max_iterations:}` — kicks off a `user.define_outcome` graded session instead of a `user.message`; mutually exclusive with `:prompt`, outcome wins; `{:error, :outcome_unsupported}` on providers without native support) ``.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/req_managed_agents/event_test.exs test/req_managed_agents/providers/claude_managed_agents_test.exs test/req_managed_agents/session_outcome_test.exs test/req_managed_agents/vocabulary_test.exs`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(cma): outcomes — Event.define_outcome/3 + :outcome kickoff (GH #31)

user.define_outcome graded sessions on Claude Managed Agents: :outcome
Session opt honored by kickoff_input (wins over :prompt), supports_outcomes?/0
capability gate ({:error, :outcome_unsupported} on AgentCore/Local), terminal
mapping for satisfied/max_iterations_reached/failed, and the explicit
needs_revision-is-not-terminal test.

Closes #31" && jj new
```

---

### Task 5: `Session.send_event/2` — mid-session raw user events

**Files:**
- Modify: `lib/req_managed_agents/session.ex` (public fn + `handle_call/3`, moduledoc)
- Test: `test/req_managed_agents/session_send_event_test.exs` (create)

**Interfaces:**
- Consumes: `provider.push_input/2` (streaming), existing live-session lifecycle (`start_link` + `notify`).
- Produces: `Session.send_event(pid(), map()) :: :ok | {:error, term()}` — posts a pre-built wire event (e.g. `Event.tool_confirmation/2`, a mid-session `Event.define_outcome/3`) into a running streaming session without driving loop state. `{:error, :unsupported}` on `:request_response` providers.

- [ ] **Step 1: Write the failing tests**

Create `test/req_managed_agents/session_send_event_test.exs`:

```elixir
defmodule ReqManagedAgents.SessionSendEventTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.{Event, Session}

  # Streaming fake that records pushed inputs instead of scripting turns.
  defmodule PushRecorder do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :streaming
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, subscriber) do
      ref = make_ref()
      send(subscriber, {:managed_agents, ref, :connected})
      {:ok, %{test_pid: opts[:test_pid], ref: ref}}
    end

    @impl true
    def kickoff_input(_opts), do: [:kickoff]
    @impl true
    def user_input(text), do: [{:user, text}]
    @impl true
    def resume_input(_uses, results), do: [{:resume, results}]
    @impl true
    def push_input(conn, events) do
      send(conn.test_pid, {:pushed, events})
      :ok
    end

    @impl true
    def turn_boundary?(_), do: false
    @impl true
    def normalize(events), do: %ReqManagedAgents.TurnResult{terminal: :terminated, events: events}
  end

  test "send_event/2 pushes the raw event on a streaming session" do
    {:ok, pid} = Session.start_link(PushRecorder, handler: fn _, _, _ -> {:ok, ""} end, test_pid: self())
    assert_receive {:pushed, [:kickoff]}

    event = Event.tool_confirmation("tu_1", :allow)
    assert :ok = Session.send_event(pid, event)
    assert_receive {:pushed, [^event]}
  end

  test "send_event/2 on a :request_response session is unsupported" do
    {:ok, pid} =
      Session.start_link(ReqManagedAgents.FakeProviders.RequestResponse,
        handler: fn _, _, _ -> {:ok, ""} end,
        turns: [[%{"type" => "stop", "terminal" => :end_turn}]]
      )

    assert {:error, :unsupported} = Session.send_event(pid, %{"type" => "user.message"})
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/req_managed_agents/session_send_event_test.exs`
Expected: FAIL — `Session.send_event/2` is undefined.

- [ ] **Step 3: Implement**

In `lib/req_managed_agents/session.ex`, next to `message/2`:

```elixir
  @doc """
  Post a pre-built raw user event (e.g. `Event.tool_confirmation/2`, a mid-session
  `Event.define_outcome/3`) into a running live session. The event is pushed verbatim —
  no turn accounting or accumulator reset. Streaming providers only:
  `{:error, :unsupported}` on `:request_response` providers (their input is consumed
  by `poll_turn/2`, there is no out-of-band channel).
  """
  @spec send_event(pid(), map()) :: :ok | {:error, term()}
  def send_event(pid, %{} = event), do: GenServer.call(pid, {:send_event, event})
```

And the callback (place before `handle_cast/2`):

```elixir
  @impl true
  def handle_call({:send_event, event}, _from, %{mode: :streaming} = s),
    do: {:reply, s.provider.push_input(s.conn, [event]), s}

  def handle_call({:send_event, _event}, _from, s), do: {:reply, {:error, :unsupported}, s}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/req_managed_agents/session_send_event_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(session): send_event/2 — mid-session raw user events (GH #31 follow-up)

Pushes a pre-built wire event (user.tool_confirmation, mid-session
define_outcome) into a running streaming session verbatim; {:error,
:unsupported} on request_response providers." && jj new
```

---

### Task 6: QA-CHECKPOINT — governance-features release gate

**Files:**
- Create: `docs/qa/<run-date>-session-governance-manual-test.md` (house header: Date / Tester / Commits under test / Worktree / Scope — no tracker ids)
- Scratch (author, run, then DELETE before committing): `test/qa_governance_scratch.exs`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces: a PASS verdict in the runbook. **Task 7 (release) does not start until PASS** — this release freezes the `turn_guard` contract, so the gate is the last cheap moment to catch a contract mistake. Failures become fix tasks, then re-run.

- [ ] **Step 1: Baseline**

`mix test 2>&1 | grep -E "^(Finished|Result)"` — record counts; the final step must reproduce them.

- [ ] **Step 2: Author and run the scratch scenarios**

The unit tasks proved each feature on the request/response fake in isolation. The gate proves the streaming path, feature *interplay*, and hostile inputs:

| # | Scenario | Method | Expected |
|---|---|---|---|
| 1 | turn_guard on a STREAMING provider | `FakeProviders.Streaming` with 3 scripted turns; guard halts at `turns >= 2` | `{:error, {:halted, _}}` + `:terminated` notify — identical semantics to the request/response fake |
| 2 | Guard vs max_turns on the same turn | `max_turns: 2`, guard halts at `turns >= 2`, scripted turns force both conditions on turn 2 | The guard wins (it runs before the `max_turns` check in `handle_turn`): `{:error, {:halted, _}}`, NOT `{:max_turns_exceeded, 2}` — record the observed order as documentation |
| 3 | Hostile guard: raises | `turn_guard: fn _ -> raise "boom" end` on a 1-turn run | `Session.run` returns `{:error, _}` (monitored DOWN); the CALLER process survives — no crash propagation |
| 4 | Hostile guard: garbage return | `turn_guard: fn _ -> :continue end` | Same containment: `{:error, _}`, caller alive (contract violation crashes the session, never the caller) |
| 5 | Guard sees re-prompt turns | enforcement on + guard that records every payload; model never calls the terminal tool | Guard invoked once per turn INCLUDING re-prompt turns, `turns` strictly increasing across them |
| 6 | `message/2` resets the re-prompt budget | live session: request 1 exhausts re-prompts (`:no_terminal_tool` notified); then `message/2` | Request 2 gets a fresh `max_reprompts` budget (observable via re-prompt count in recorded inputs) |
| 7 | `rma.text_delta` at the wire | Bypass SSE Claude session: one `agent.message` with two text blocks, then `end_turn` | Handler receives the raw `agent.message` then ONE synthetic `%{"type" => "rma.text_delta", "text" => <joined>}`; `SessionResult.events` contains no synthetic |
| 8 | Outcome loop with tools mixed in | Bypass SSE: outcome kickoff → `custom_tool_use` + `requires_action` idle → (turn 2) `span.outcome_evaluation_end` needs_revision → `agent.message` → `status_idle` satisfied | Tool ran; `needs_revision` did not terminate; result `terminal: :end_turn`, `stop_reason: %{"type" => "satisfied"}`, `turns: 2` |
| 9 | `send_event/2` reaches the wire | Bypass CMA live session; `send_event(pid, Event.tool_confirmation("tu_1", :allow))` | The events POST body carries the tool_confirmation verbatim; no turn counted |
| 10 | LIVE outcome session (optional leg) | First verify key presence, count only: `grep -c ANTHROPIC_API_KEY .env`. If present: real CMA session, cheap model, trivially satisfiable rubric, `max_iterations: 2` | Terminal only at `status_idle`; record the observed `stop_reason.type` (`satisfied` expected) and the event-type sequence in the runbook. If no key: mark the leg **SKIPPED** — never report a skip as a pass |

- [ ] **Step 3: Clean up and confirm the baseline**

Delete the scratch file; `mix test` reproduces Step 1's counts exactly. Record.

- [ ] **Step 4: Verdict + commit**

Runbook ends with `RESULT: PASS — N/N scenarios (M skipped-live)`. Commit:

```bash
jj describe -m "qa: session-governance release-gate checkpoint (PASS)" && jj new
```

---

### Task 7: Release 0.5.0 — version bump + CHANGELOG

**Files:**
- Modify: `mix.exs:4` (`@version "0.4.1"` → `@version "0.5.0"`)
- Modify: `CHANGELOG.md` (new entry above `## v0.4.1`)

**Interfaces:**
- Consumes: Tasks 1–5; Task 6's PASS verdict.
- Produces: version `0.5.0` — **the turn_guard contract is frozen from here** (mimir 0.2.0 and the 0.6.0 plan build on it).

- [ ] **Step 1: Bump the version**

In `mix.exs`: `@version "0.5.0"`.

- [ ] **Step 2: Add the CHANGELOG entry**

Insert above `## v0.4.1`:

```markdown
## v0.5.0 (2026-07-04)

### Added
- **`turn_guard`** — the between-turn governance hook, invoked after each turn's usage
  accumulation with plain data (`%{usage: %{input_tokens:, output_tokens:, raw:}, turns:,
  session_id:}`), returning `:cont` or `{:halt, reason}`. On halt the run stops with
  `{:error, {:halted, reason}}` and a `:terminated` `SessionResult` is notified. This
  contract is frozen: hosts compose policy (budget caps, grant checks) on top; RMA ships
  only the mechanism.
- Terminal-tool enforcement: `require_terminal_tool: true` + `terminal_tool: "name"` +
  `max_reprompts` (default 2). An `:end_turn` that never called the terminal tool is
  re-driven with a re-prompt; exhausted re-prompts finish with
  `stop_reason: :no_terminal_tool`. Re-prompt turns count against `:max_turns`.
- `rma.text_delta` — one documented synthetic event
  (`%{"type" => "rma.text_delta", "text" => chunk}`) emitted through `handle_event`
  alongside (never instead of) the raw event, on every provider that implements the new
  optional `Provider.text_delta/1`. Never stored in `SessionResult.events`.
- Outcomes (GH #31): `Event.define_outcome/3`, the `:outcome` Session option honored by
  the Claude Managed Agents kickoff (`user.define_outcome`; mutually exclusive with
  `:prompt`, outcome wins), optional `Provider.supports_outcomes?/0`
  (`{:error, :outcome_unsupported}` on Bedrock AgentCore), and terminal mapping for
  outcome stop reasons (`satisfied`/`max_iterations_reached` → `:end_turn`, `failed` →
  `:terminated`; `span.outcome_evaluation_end` with `needs_revision` is not terminal).
- `Session.send_event/2` — post a pre-built raw user event (e.g.
  `user.tool_confirmation`) into a running streaming session.

### Changed
- `TurnResult`/`SessionResult` `stop_reason` typespec widened to
  `String.t() | map() | atom() | nil` (`:no_terminal_tool`).
```

- [ ] **Step 3: Verify the release builds clean**

Run: `mix test && mix docs`
Expected: suite green; docs build without warnings.

- [ ] **Step 4: Commit**

```bash
jj describe -m "release: v0.5.0 — turn_guard, terminal-tool enforcement, rma.text_delta, outcomes" && jj new
```
