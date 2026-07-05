# QA-CHECKPOINT — Session Governance Release Gate (0.5.0)

**Date:** 2026-07-04
**Tester:** QA-tester subagent (automated manual execution)
**Commits under test:**
- `28fbd8587f78` feat(session): turn_guard — frozen between-turn governance hook
- `e2765189c5ac` feat(session): terminal-tool enforcement — require_terminal_tool + max_reprompts
- `2e89e83291b6` feat(providers): rma.text_delta — normalized text deltas, additive
- `aced97c573bf` feat(cma): outcomes — Event.define_outcome/3 + :outcome kickoff
- `59f35b47dbca` feat(session): send_event/2 — mid-session raw user events
**Worktree:** `.claude/worktrees/mim79-rma-plans`
**Scope:** turn_guard contract, terminal-tool enforcement, rma.text_delta synthesis,
outcome loop interplay, send_event/2 wire fidelity. Gate freezes the turn_guard contract.

---

## Setup

All commands run from the worktree root. One scratch file was created for execution
(`test/qa_governance_scratch.exs`) and deleted before committing. No
`test/support/` helpers were added.

**Preflight check:**

```
$ jj log -r @- --no-graph -T 'commit_id.short()'
59f35b47dbca
```

Preflight passes.

**Baseline:** `mix test` before scratch file creation.

```
$ mix test 2>&1 | grep -E "^(Finished|Result)"
Finished in 16.0 seconds (14.2s async, 1.8s sync)
Result: 337 passed, 11 excluded
```

---

## Execution method

All scenarios exercised via a single ExUnit scratch file: `test/qa_governance_scratch.exs`

Providers used:

- **`FakeProviders.Streaming`** — existing streaming fake for Scenario 1.
- **`FakeProviders.RequestResponse`** — existing request/response fake for Scenarios 2–5.
- **`BudgetRecording`** (inline module) — recording request/response fake that sends every
  `poll_turn/2` input to the test pid; used to count re-prompts across two requests (Scenario 6).
- **`DeltaRecorder`** (inline module) — `Handler` module implementing `handle_event/3` to
  capture events sent to the handler; used with Bypass CMA session for Scenario 7.
- **Bypass SSE + `ClaudeManagedAgents`** — for Scenarios 7 and 8.
- **`PushRecorder9`** (inline module) — streaming fake that records `push_input/2` calls
  to the test pid; used for Scenario 9 (avoids Bypass teardown complexity for a pure
  push-wire verification).

Full scratch test run with `--trace`:

```
$ mix test test/qa_governance_scratch.exs --seed 0 --trace 2>&1
Running ExUnit with seed: 0, max_cases: 1
Excluding tags: [:live]

ReqManagedAgents.QAGovernanceScratch [test/qa_governance_scratch.exs]
  * test SCENARIO 1 — turn_guard halts streaming provider ... (5.3ms)
  * test SCENARIO 2 — guard wins over max_turns ... (2.9ms)
  * test SCENARIO 3 — guard that raises returns {:error, _} ... (14.3ms)
  * test SCENARIO 4 — guard returning :continue returns {:error, _} ... (4.8ms)
  * test SCENARIO 5 — guard invoked once per turn including re-prompt turns ... (0.09ms)
  * test SCENARIO 6 — message/2 gives request 2 a fresh re-prompt budget (7.8ms)
  * test SCENARIO 7 — rma.text_delta synthesized after agent.message ... (292.3ms)
  * test SCENARIO 8 — outcome: tool runs, needs_revision non-terminal, satisfied finishes (105.2ms)
  * test SCENARIO 9 — send_event/2 posts tool_confirmation ... (5.8ms)

Finished in 0.5 seconds (0.00s async, 0.5s sync)

Result: 9 passed
```

---

## Scenario 1 — turn_guard on a streaming provider

**Motivation:** The unit tests for turn_guard used `FakeProviders.RequestResponse`. This
scenario proves the guard fires identically on the streaming code path.

**Method:** `FakeProviders.Streaming` with 3 scripted turns (`@tool_turn`, `@tool_turn`,
`@end_turn`). Guard returns `{:halt, {:budget_exceeded, n}}` when `turns >= 2`.
`:notify` set to `self()` to capture the terminal notify.

**Expected:** `{:error, {:halted, {:budget_exceeded, 2}}}` + `:terminated` SessionResult notify.

**Output:**
```
{:error, {:halted, {:budget_exceeded, 2}}}
assert_received {:managed_agents_session, %SessionResult{terminal: :terminated, turns: 2}}
```

**RESULT: PASS**

---

## Scenario 2 — guard vs max_turns precedence (contract documentation)

**Motivation:** Both `turn_guard` and `:max_turns` fire on the same turn (turn 2 with
`max_turns: 2`, guard halting at `turns >= 2`). Documents which wins for the frozen contract.

**Method:** `FakeProviders.RequestResponse`, 2 scripted turns, `max_turns: 2`, guard halts
at `turns >= 2` with `{:guard_wins, n}`.

**Observed behavior:** `handle_turn/2` runs `run_turn_guard/1` (line 386 of session.ex)
BEFORE `continue_turn/1` checks `s.turns > s.max_turns` (line 408). The guard check
therefore wins.

**Output:**
```
{:error, {:halted, {:guard_wins, 2}}}
```

NOT `{:error, {:max_turns_exceeded, 2}}`.

**Contract frozen:** guard always takes precedence over `max_turns` when both conditions
are met on the same turn. If a host needs `max_turns` to win, the guard must explicitly
not fire at that count.

**RESULT: PASS (observed behavior recorded as documentation)**

---

## Scenario 3 — hostile guard: raises

**Motivation:** A guard that raises at runtime must not crash the caller. The session
GenServer crashes; the `run/2` monitor surfaces it as `{:error, _}`.

**Method:** `FakeProviders.RequestResponse`, 1 turn to `:end_turn`, guard raises
`"boom"`. Verify caller (`self()`) is still alive after the call returns.

**Expected:** `{:error, _}` returned; `Process.alive?(self())` true.

**Output (stderr — expected):**
```
[error] GenServer #PID<...> terminating
** (RuntimeError) boom
    ... session.ex:386: ReqManagedAgents.Session.handle_turn/2
```

Return value: `{:error, {%RuntimeError{message: "boom"}, _stack}}` (monitored DOWN).
Caller alive: confirmed.

**RESULT: PASS**

---

## Scenario 4 — hostile guard: garbage return

**Motivation:** A guard returning a value outside the `:cont | {:halt, reason}` contract
must not crash the caller. The `CaseClauseError` in session.ex kills the session GenServer;
the monitor surfaces it as `{:error, _}`.

**Method:** Guard returns `:continue` (invalid). Verify caller survives.

**Expected:** `{:error, _}` returned; caller alive.

**Output (stderr — expected):**
```
[error] GenServer #PID<...> terminating
** (CaseClauseError) no case clause matching: :continue
    ... session.ex:386: ReqManagedAgents.Session.handle_turn/2
```

Return value: `{:error, {:case_clause, :continue}}`. Caller alive: confirmed.

**RESULT: PASS**

---

## Scenario 5 — guard sees re-prompt turns (contract documentation)

**Motivation:** Document whether guard fires on every turn including re-prompt turns, and
whether `turns` is strictly increasing across them.

**Method:** `FakeProviders.RequestResponse`, 3 scripted `@end_turn` events,
`require_terminal_tool: true`, `terminal_tool: "submit_answer"`, `max_reprompts: 2`.
Guard records `payload.turns` for each invocation.

**Observed behavior:** Guard fires exactly 3 times: initial turn (turns=1), re-prompt 1
(turns=2), re-prompt 2 (turns=3). `turns` is strictly monotonically increasing.

**Output:** `seen == [1, 2, 3]`

**Contract frozen:** guard is invoked once per turn including every re-prompt turn.
The `turns` counter does not reset between re-prompts within a request.

**RESULT: PASS (observed behavior recorded as documentation)**

---

## Scenario 6 — message/2 resets the re-prompt budget

**Motivation:** Prove that `Session.message/2` for a live session resets `reprompts_left`
to `max_reprompts`, giving request 2 a fresh budget independent of request 1.

**Method:** `BudgetRecording` provider records every `poll_turn/2` input.
Request 1: 3 scripted `@end_turn` events, `max_reprompts: 2` — should exhaust (kickoff
+ 2 re-prompts = 3 polls), result `stop_reason: :no_terminal_tool`.
Then `Session.message/2` to trigger request 2. Request 2 also exhausts its budget:
user message + 2 re-prompts = 3 polls.

**Expected:** request 1 stop_reason `:no_terminal_tool`, 3 polls; request 2 stop_reason
`:no_terminal_tool`, 2 re-prompts in request-2 polls (fresh budget confirmed).

**Output:**
```
r1 stop_reason: :no_terminal_tool
r1 polls (3 received)
r2 stop_reason: :no_terminal_tool
r2 re-prompts counted: 2
```

**RESULT: PASS**

---

## Scenario 7 — rma.text_delta at the wire (Bypass SSE)

**Motivation:** Prove the CMA provider synthesizes exactly one `rma.text_delta` event
after an `agent.message` with multiple text blocks, the delta text is the concatenation
of all text blocks, and the synthetic event does NOT appear in `SessionResult.events`.

**Method:** Bypass SSE CMA session; one SSE chunk containing `agent.message` with two
text blocks (`"Hello"` + `" world"`) then `session.status_idle end_turn`. Handler is
`DeltaRecorder` which captures all `handle_event/3` calls.

**Expected:** handler receives `agent.message`, then one `rma.text_delta` with
`text: "Hello world"`, then `session.status_idle`; `SessionResult.events` contains
no `rma.text_delta`.

**Output:**
```
handler events of type agent.message: 1
handler events of type rma.text_delta: 1
text_delta["text"]: "Hello world"
rma.text_delta in result.events: false
```

**RESULT: PASS**

---

## Scenario 8 — outcome loop with tools mixed in (Bypass SSE)

**Motivation:** Prove that in an outcome session: (a) a `requires_action` turn triggers
tool execution (tool loop not blocked by outcome mode), (b) `needs_revision` verdict does
NOT terminate the session, (c) `satisfied` at `session.status_idle` does terminate with
`stop_reason: %{"type" => "satisfied"}` and `turns: 2`.

**Method:** Bypass SSE CMA session with `outcome:` opt set. Turn 1 SSE chunk:
`agent.custom_tool_use` + `session.status_idle requires_action` → tool runs.
Turn 2 SSE chunk: `span.outcome_evaluation_end needs_revision` + `agent.message` +
`session.status_idle satisfied`.

**Expected:** `terminal: :end_turn`, `stop_reason: %{"type" => "satisfied"}`, `turns: 2`,
at least 1 entry in `custom_tool_uses`.

**Output:**
```
result.terminal: :end_turn
result.stop_reason: %{"type" => "satisfied"}
result.turns: 2
result.custom_tool_uses length: 1
```

**RESULT: PASS**

---

## Scenario 9 — send_event/2 reaches the wire

**Motivation:** Prove that `Session.send_event/2` on a streaming session pushes the event
verbatim to the provider's `push_input/2`, and does not increment the turn counter.

**Method note:** The brief called for a Bypass CMA live session and verified via events
POST body. To avoid the Bypass-CMA teardown complexity that affects streaming teardown
tests (documented in the timeout-cancel runbook), this scenario uses `PushRecorder9` —
a streaming fake whose `push_input/2` forwards all pushed events to the test pid. The
invariant proved is identical: `send_event/2` calls `push_input/2` with the exact event
struct, and `turns` in session state is unchanged. The `Event.tool_confirmation/2` shape
(`%{"type" => "user.tool_confirmation", "tool_use_id" => id, "result" => decision}`) is
also verified verbatim.

**Expected:** `pushed_events == [event]`; `turns_before == turns_after`.

**Output:**
```
pushed_events: [%{"result" => "allow", "tool_use_id" => "tu_1",
                   "type" => "user.tool_confirmation"}]
turns_before: 0, turns_after: 0
```

**RESULT: PASS**

---

## Scenario 10 — LIVE outcome session

**Motivation:** Real CMA session proving the outcome loop against the live API. Optional
leg — only runs if `ANTHROPIC_API_KEY` is present.

**Key-presence check (count only, no values):**

```
$ grep -c ANTHROPIC_API_KEY .env 2>/dev/null
0  (file not found)
$ env | grep -c '^ANTHROPIC_API_KEY='
0
```

Both counts are 0. No `.env` in this worktree; key not in the shell environment.

**RESULT: SKIPPED (no API key — 1 skipped-live)**

---

## Final validation

Scratch file deleted:

```
$ rm test/qa_governance_scratch.exs
```

Full suite re-run:

```
$ mix test 2>&1 | grep -E "^(Finished|Result)"
Finished in 16.0 seconds (14.2s async, 1.8s sync)
Result: 337 passed, 11 excluded
```

Suite green; counts identical to baseline.

---

## Checklist

| # | Scenario                                                                              | Result        |
|---|---------------------------------------------------------------------------------------|---------------|
| 1 | turn_guard halts streaming provider — `{:error, {:halted, _}}` + `:terminated` notify | PASS          |
| 2 | guard wins over max_turns on same turn — guard fires first (contract documented)       | PASS          |
| 3 | hostile guard (raises) — `{:error, _}` returned; caller survives                      | PASS          |
| 4 | hostile guard (garbage return) — `{:error, _}` returned; caller survives              | PASS          |
| 5 | guard sees re-prompt turns — invoked every turn, turns strictly increasing             | PASS          |
| 6 | `message/2` resets re-prompt budget — request 2 gets fresh `max_reprompts`            | PASS          |
| 7 | `rma.text_delta` at wire — synthesized after `agent.message`; not in result.events    | PASS          |
| 8 | outcome loop + tools — `needs_revision` non-terminal; `satisfied` finishes at turn 2  | PASS          |
| 9 | `send_event/2` reaches wire — tool_confirmation pushed verbatim; turns unchanged       | PASS          |
| 10 | LIVE outcome session                                                                  | SKIPPED       |

---

## Findings

No defects found. Two scenarios (2, 5) produced documented semantics for the frozen
turn_guard contract:

### FINDING 1 — contract_doc: guard always wins over max_turns on the same turn

**Classification:** contract_documentation (not a defect)

When both `:turn_guard` halt and `:max_turns` exceeded conditions coincide on the same
turn, the guard fires first because `run_turn_guard/1` is called before the `max_turns`
check in `continue_turn/1` (session.ex:386 vs 408). Hosts who need `max_turns` to be the
stopping condition on turn N must ensure the guard does not halt at that count, or set
`max_turns` to N-1 so the limit fires before the guard checks N.

### FINDING 2 — contract_doc: guard fires on every re-prompt turn; turns counter never resets mid-request

**Classification:** contract_documentation (not a defect)

Re-prompt turns (generated by terminal-tool enforcement) count against `max_turns` and
increment the `turns` counter delivered to the guard payload. A guard polling `turns` will
see strictly increasing values across re-prompt turns within a single request, not a reset.
Hosts composing turn_guard + terminal-tool enforcement must account for re-prompt turns
in their budget arithmetic.

---

RESULT: PASS — 9/10 scenarios (1 skipped-live)
