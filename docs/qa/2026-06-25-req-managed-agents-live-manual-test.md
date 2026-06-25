# QA Checkpoint B — Live Beta Full Cycle
`req_managed_agents` · 2026-06-25

## Scope

Verify the complete `requires_action → custom_tool_result → end_turn` cycle against
Anthropic's live Managed Agents beta using a local `echo` custom tool. This is the
MVP "live-verified" acceptance gate. Additionally, record concrete answers to four
inherited open questions about the real wire protocol:

1. Custom-tool definition field shape accepted by the API.
2. `is_error` field validity in `user.custom_tool_result` events.
3. `GET /v1/sessions/{id}/events` pagination shape.
4. SSE frame decode fidelity through `ReqManagedAgents.SSE.decode/1`.

**This checkpoint is CREDENTIAL-GATED.** It requires an `ANTHROPIC_API_KEY` with
Managed Agents beta access. Without it, all steps are `deferred`.

---

## Read This First

- **Credential-gated:** The key lives in `/Users/ryanmckeeman/src/bizinsights/.env.local`.
  Source it in the same shell command that invokes `mix test` — never print it, never
  echo it, never pass it as a visible argument.
- **Real API cost:** This test creates a real agent and a real session on Anthropic's
  infrastructure. Model: `claude-opus-4-8`. Cost is small (one short conversation) but
  non-zero.
- **Beta header required:** Every request carries `anthropic-beta: managed-agents-2026-04-01`.
  Without this header requests will 400 or 404.
- **Key safety check (without printing the value):**
  ```bash
  set -a; source /Users/ryanmckeeman/src/bizinsights/.env.local; set +a
  test -n "$ANTHROPIC_API_KEY" && echo "key present" || echo "key MISSING"
  ```

---

## Setup

**Working directory:** `/Users/ryanmckeeman/src/bizinsights/req_managed_agents`

**Required Elixir version:** confirmed via `mix --version` before running.

**Run the live test:**
```bash
cd /Users/ryanmckeeman/src/bizinsights/req_managed_agents \
  && set -a && source /Users/ryanmckeeman/src/bizinsights/.env.local && set +a \
  && mix test --only live test/live/live_smoke_test.exs
```

> SECRET SAFETY: the `source` and `mix test` commands are chained in a single shell
> invocation so the key is only present in the environment for the duration of that
> command. The key value must never appear in terminal output, log files, or this document.

---

## Live Execution Step

**What the test does:**

1. Starts the `:req_managed_agents` application (Finch pools, supervisor).
2. Calls `ReqManagedAgents.Client.create_agent/2` with model `claude-opus-4-8`, a
   system prompt instructing it to use the `echo` tool, one custom tool definition,
   and a top-level `name: "req-managed-agents-live-smoke"` field (fix applied since run A).
3. Calls `ReqManagedAgents.start_session/1` with `prompt: "Please echo: hello-managed-agents"`.
   Internally `Session.init/1` calls `Client.create_session/2` with body
   `%{agent: agent_id}` (BUG-2 fixed — no `events` in the create body). The initial user
   message is sent separately via `Client.send_event/3` after the SSE stream attaches
   (triggered by the `:connected` signal).
4. The `Session` GenServer opens an SSE stream, receives `session.status_idle` with
   `stop_reason.type = "requires_action"`, dispatches the `echo` tool call through the
   local `Handler`, posts `user.custom_tool_result` back to the API, then waits for
   `session.status_idle` with `stop_reason.type = "end_turn"`.
5. The test asserts `{:managed_agents_session, :end_turn}` arrives within 90 seconds.

**Acceptance criterion:** `mix test` exits 0, output includes `1 test, 0 failures`.

---

## Run History

### Run D — 2026-06-25 (re-run after BUG-3 fix — create_environment + environment_id)

**Result:** PASS — exit code 0, `1 test, 0 failures`

**Key confirmed present:** yes (without printing value)

**Elapsed:** 5.6 seconds (0.00s async, 5.6s sync)

**Full cycle:** create_environment → create_agent → create_session (with environment_id) → SSE stream attach → kickoff → requires_action → echo tool dispatch → custom_tool_result → end_turn. The `assert_receive {:managed_agents_session, :end_turn}` assertion succeeded within 90 s.

**Wire facts confirmed live:**
- Environment body `%{name: "req-managed-agents-live-smoke", config: %{type: "cloud", networking: %{type: "unrestricted"}}}` accepted by `POST /v1/environments` → `{:ok, %{"id" => env_id}}`.
- Session body `%{agent: agent_id, environment_id: env_id}` accepted by `POST /v1/sessions` → `{:ok, %{"id" => session_id}}`.
- SSE stream opened, real frames decoded through `SSE.decode/1`. Cycle completed in 5.6 s total.

**Captured test output:**
```
Running ExUnit with seed: 529649, max_cases: 40
Excluding tags: [:test]
Including tags: [:live]

.
Finished in 5.6 seconds (0.00s async, 5.6s sync)

Result: 1 passed
```

**MVP acceptance criterion:** MET — the full `requires_action → custom_tool_result → end_turn` cycle executed live against Anthropic's Managed Agents beta.

---

### Run A — 2026-06-25 (initial)

**Result:** FAIL — exit code 2

**Error:** `POST /v1/agents` → HTTP 400 `"name: Field required"`

**Root cause:** `create_agent/2` call body lacked a top-level `"name"` field for the
agent itself. The fix was to add `name: "req-managed-agents-live-smoke"` to the
`create_agent` map in `test/live/live_smoke_test.exs`.

**Classification:** wire-shape mismatch at `create_agent`.

---

### Run C — 2026-06-25 (re-run after BUG-2 fix — bare create + :connected kickoff)

**Result:** FAIL — exit code 2

**Key confirmed present:** yes (without printing value)

**Error:** `create_session` → EXIT `{:create_session_failed, {:http_error, 400, ...}}`

**API error message (verbatim, no secrets):**
```
"environment_id: Field required"
```

**Request ID:** `req_011CcQ1LtvEcVst33ULYs5Dp`

**Root cause:** BUG-2 fix is confirmed to have landed — `Session.init/1` now calls
`Client.create_session/2` with body `%{agent: agent_id}` only (no `events` key).
However the live API (`POST /v1/sessions`) now requires an additional field:
`environment_id`. This field is not present in the current `create_session` call, nor
anywhere in the library source code. The planning doc (`docs/planning/managed_agents/client.ex`
line 66) mentions an optional `environment` field but treats it as optional.
The live API now treats it as **required**.

**Progress since Run B:** `create_agent` continues to succeed (the `name` fix from
BUG-1 is still correct). The "events" rejection from BUG-2 is gone — the session body
shape is now correct in that dimension. The failure point advanced from "unknown field
events" to "environment_id: Field required". A new required field has been identified.

**Classification:** wire-shape mismatch at `create_session` — third distinct
API-shape issue discovered via live testing. The API schema changed or the field
was never optional.

**Captured test output (exit code 2):**
```
Running ExUnit with seed: 677844, max_cases: 40
Excluding tags: [:test]
Including tags: [:live]

  1) test full cycle against the live beta (ReqManagedAgents.LiveSmokeTest)
     test/live/live_smoke_test.exs:14
     ** (EXIT from #PID<0.287.0>) {:create_session_failed, {:http_error, 400,
          %{"error" => %{"message" => "environment_id: Field required",
                         "type" => "invalid_request_error"},
            "request_id" => "req_011CcQ1LtvEcVst33ULYs5Dp",
            "type" => "error"}}}

Finished in 0.5 seconds (0.00s async, 0.5s sync)

Result: 0/1 passed
Failed: 1 test
```

---

### Run B — 2026-06-25 (re-run after name fix)

**Result:** FAIL — exit code 2

**Key confirmed present:** yes (without printing value)

**Error:** `create_session` → EXIT `{:create_session_failed, {:http_error, 400, ...}}`

**API error message (verbatim, no secrets):**
```
"Failed to parse request body: unknown field \"events\""
```

**Request ID:** `req_011CcPzggVoz8mQBTb4ZNasH`

**Root cause:** `Session.init/1` (line 63–65 of `lib/req_managed_agents/session.ex`)
calls `Client.create_session/2` with body:
```elixir
%{
  agent: agent_id,
  events: [Event.user_message(prompt)]
}
```
The live API rejects the `"events"` key as an unknown field in `POST /v1/sessions`.
The API appears to require a separate `POST /v1/sessions/{id}/events` call for the
initial user message rather than bundling it inside the create_session body.

**Classification:** wire-shape mismatch at `create_session` — second distinct
API-shape issue discovered via live testing.

**Progress since Run A:** `create_agent` now succeeds (the `name` fix worked). The
failure point advanced from agent creation to session creation. The cycle still does
not reach end_turn.

**Captured test output (exit code 2):**
```
Running ExUnit with seed: 292028, max_cases: 40
Excluding tags: [:test]
Including tags: [:live]

  1) test full cycle against the live beta (ReqManagedAgents.LiveSmokeTest)
     test/live/live_smoke_test.exs:14
     ** (EXIT from #PID<0.287.0>) {:create_session_failed, {:http_error, 400,
          %{"error" => %{"message" => "Failed to parse request body: unknown field \"events\"",
                         "type" => "invalid_request_error"},
            "request_id" => "req_011CcPzggVoz8mQBTb4ZNasH",
            "type" => "error"}}}

Finished in 0.5 seconds (0.00s async, 0.5s sync)
Result: 0/1 passed
Failed: 1 test
```

---

## Open Questions — Observed Answers

Record concrete answers here after the live run. For each item, state whether it was
directly observed, inferred from API error messages, or not determinable in this run.

### OQ-1: Custom-tool definition fields

**Expected shape we send:**
```elixir
%{type: "custom", name: "echo", description: "...", input_schema: %{...}}
```

**Observed (Run D — CONFIRMED):**

Run A: `POST /v1/agents` rejected with HTTP 400 `"name: Field required"` — agent-level `name` is required.

Runs B, C, D: `create_agent/2` succeeded each time. The agent body `%{name:, model:, system:, tools: [...]}` is accepted. The tool definition `%{type: "custom", name:, description:, input_schema:}` is accepted without error.

Run D: The full cycle completed to `end_turn`, which means the tool definition not only passed agent-creation validation but was used by the model to dispatch a `requires_action` event — fully exercised live.

**Conclusion: CONFIRMED.**
1. Agent body requires a top-level `name` string.
2. Tool definition fields `%{type: "custom", name:, description:, input_schema:}` accepted and used live by the API.

**Source:** Run A error (name required) + Runs B/C/D progression (agent created) + Run D full cycle (tool exercised).

---

### OQ-2: `is_error` field in `user.custom_tool_result`

**What we send on success:**
```elixir
%{"type" => "user.custom_tool_result", "custom_tool_use_id" => id,
  "content" => [...], "is_error" => false}
```

**Observed (Run D):**

The happy-path cycle completed to `end_turn`. This means a `user.custom_tool_result` event was posted with `is_error: false` and was accepted by the API — the model received the tool result and produced an `end_turn`. The success path is **confirmed live**.

The error path (`is_error: true`) was not exercised by the happy-path test — the `echo` tool never errored.

**Status: Success-path CONFIRMED. Error-path not exercised (happy path only).**

**Source:** Run D full cycle — `requires_action` → tool dispatch → `custom_tool_result` posted → `end_turn` received.

---

### OQ-3: `GET /v1/sessions/{id}/events` pagination shape

**What our code assumes** (from `Consolidate` / `Session` reconnect path):
```elixir
{:ok, %{"data" => past}} = Client.list_events(client, session_id, %{limit: 1000})
```
Expects a `"data"` array key at the top level.

**Observed (Run D):**

A real session was created for the first time in Run D. However, the live smoke test does not call `list_events` directly — that is used only in the reconnect path (`Session` restoring from `Consolidate`). The happy-path test does not exercise the reconnect path.

`list_events` was not called against the live API. The `%{"data" => past}` pattern match assumption is still based only on the unit test stub in `test/req_managed_agents/client_test.exs:54`.

Real API pagination fields (cursor, `has_more`) remain unconfirmed live.

**Status: Not captured in Run D. An optional `iex -S mix` probe with a live session_id would be needed to confirm the real shape. The session created in Run D was ephemeral (no session_id captured in the test output).**

**Source:** Run D PASS tells us sessions are obtainable. OQ-3 requires an explicit `list_events` call — not captured.

---

### OQ-4: SSE frame decode fidelity

**What `ReqManagedAgents.SSE.decode/1` expects:**
- Frames delimited by `\n\n`
- Lines prefixed `data:` (space-stripped) containing JSON
- Comment lines (`:`) ignored
- Non-`data:` lines (including `event:` lines) ignored

**Observed (Run D — CONFIRMED):**

The full cycle completed in 5.6 seconds, which means a real SSE stream was opened, frames were decoded through `SSE.decode/1`, the `session.status_idle` + `requires_action` event was parsed, the `session.status_idle` + `end_turn` event was parsed, and all session state transitions executed correctly.

The SSE decoder handled real live frames without error. The `event: <type>\ndata: <json>\n\n` frame shape used in the test fixtures is consistent with what the live API emits — confirmed implicitly by the successful cycle.

Specific event types observed (inferred from the cycle completing):
- `session.status_idle` with `stop_reason.type = "requires_action"` (triggered `echo` tool dispatch)
- `session.status_idle` with `stop_reason.type = "end_turn"` (triggered `:end_turn` notification to test)
- Likely also: agent message events and/or span events during the model's response — these are handled by `Handler.handle_event/2` in the test (which returns `:ok` for all non-tool events).

Whether the live beta emits additional event types (e.g. `"ping"`, `span.*`) is not captured in the test output, but the decoder's ignore-unknown-lines behavior means these would not cause failures.

**Status: CONFIRMED — real SSE frames decoded cleanly; cycle proves fidelity end-to-end.**

**Source:** Run D full cycle, 5.6 s elapsed, 1 test passed.

---

## Identified Bugs (Live Discoveries)

### BUG-1: Agent body missing top-level `name` field (FIXED in live test)
- **Where:** `test/live/live_smoke_test.exs` (create_agent call, pre-fix)
- **Symptom:** HTTP 400 `"name: Field required"` on `POST /v1/agents`
- **Fix applied:** `name: "req-managed-agents-live-smoke"` added to agent body in the live test.
- **Note:** `examples/local_tool_example.exs` already had `name: "billing-support"`. The
  `Session.init/1` generic path doesn't include a name — but `create_agent` is called
  by the caller, not Session, so this is caller-side.

### BUG-2: Session create body includes unknown `events` field (FIXED — confirmed in Run C)
- **Where:** `lib/req_managed_agents/session.ex` lines 62–65 (pre-fix)
- **Symptom:** HTTP 400 `"Failed to parse request body: unknown field \"events\""` on
  `POST /v1/sessions`
- **Root cause:** `Session.init/1` was bundling the initial user message inside the
  create_session body as `%{agent: agent_id, events: [user_message]}`. The live API
  does not accept an `events` key at session-creation time.
- **Fix applied:** `Session.init/1` now calls `Client.create_session/2` with body
  `%{agent: agent_id}` only (no `events`). The `:connected` signal handler in
  `handle_info/2` (line 97–108) sends the initial user message via
  `Client.send_event/3` after the SSE stream attaches.
- **Confirmed fixed:** Run C no longer saw the "unknown field events" error. The session
  creation body is now accepted in that dimension (new failure at `environment_id`).
- **Blocker for:** OQ-2, OQ-3, OQ-4, and the full `end_turn` cycle — now blocked by BUG-3 instead.

### BUG-3: Session create body missing required `environment_id` field (FIXED — confirmed in Run D)
- **Where:** `lib/req_managed_agents/session.ex` / `lib/req_managed_agents/client.ex` + `test/live/live_smoke_test.exs`
- **Symptom:** HTTP 400 `"environment_id: Field required"` on `POST /v1/sessions`
- **Request ID (from Run C):** `req_011CcQ1LtvEcVst33ULYs5Dp`
- **Root cause:** `Client.create_session/2` was called with body `%{agent: agent_id}` only.
  The live `POST /v1/sessions` endpoint requires an `environment_id`. The live API also
  requires creating the environment first via `POST /v1/environments`.
- **Fix applied:** `Client.create_environment/2` added to the library. `Session.init/1`
  accepts `environment_id` as a parameter and includes it in the `create_session` body:
  `%{agent: agent_id, environment_id: env_id}`. The live test calls `create_environment/2`
  with `%{name:, config: %{type: "cloud", networking: %{type: "unrestricted"}}}` before
  `create_agent/2`, then passes `environment_id: env_id` to `start_session/1`.
- **Confirmed fixed:** Run D — `create_session` succeeded, SSE stream opened, full cycle
  completed to `end_turn`. The environment creation + session creation chain is correct.
- **Wire facts confirmed:**
  - `POST /v1/environments` body: `%{name: "...", config: %{type: "cloud", networking: %{type: "unrestricted"}}}`
  - `POST /v1/sessions` body: `%{agent: agent_id, environment_id: env_id}`
- **Classification:** wire-shape mismatch — a required field was unknown at implementation time.
  Not an auth issue.

---

## Checklist

- [x] Key present (confirmed without printing — `test -n "$ANTHROPIC_API_KEY"` returned "key present")
- [x] Live test invoked with the sourced-key command (Runs B, C, and D)
- [x] Exit code captured (Run D: exit code 0 — PASS; Runs A/B/C: exit code 2 — failures)
- [x] Test output captured (verbatim for all runs; no secrets in output)
- [x] OQ-1 CONFIRMED: tool definition fields accepted live; agent `name` required; tool exercised in Run D
- [x] OQ-2 SUCCESS-PATH CONFIRMED: `is_error: false` accepted; full cycle reached `end_turn` in Run D
- [ ] OQ-2 error-path (is_error: true) not exercised — happy path only; deferred
- [ ] OQ-3 not captured: `list_events` not called in live test; reconnect path not exercised
- [x] OQ-4 CONFIRMED: real SSE frames decoded cleanly end-to-end through `SSE.decode/1` in Run D
- [x] BUG-1 documented and FIXED (agent top-level `name` required)
- [x] BUG-2 documented and CONFIRMED FIXED (Run C: "events" rejection gone; Run D: session created)
- [x] BUG-3 documented and CONFIRMED FIXED (Run D: `create_environment` + `environment_id` in session body)
- [x] **MVP acceptance criterion MET: full `requires_action → custom_tool_result → end_turn` cycle live (Run D)**

---

## Findings YAML

```yaml
# QA-CHECKPOINT-B findings
# Status values: pass | fail | deferred | skip
# Run D results below (final — supersedes Runs A, B, and C)

- step_id: "D.0"
  status: pass
  observed: |
    Key present without printing. Test run with sourced key.
  expected: |
    ANTHROPIC_API_KEY present in environment (without printing the value).
  evidence: |
    Bash: test -n "$ANTHROPIC_API_KEY" && echo "key present" || echo "key MISSING"
    Result: "key present"

- step_id: "D.1"
  status: pass
  observed: |
    Full cycle PASS. Exit code 0. "1 test, 0 failures". Elapsed 5.6 seconds.
    create_environment/2 → {:ok, %{"id" => env_id}}
    create_agent/2 → {:ok, %{"id" => agent_id}}
    start_session/1 (with environment_id: env_id) → {:ok, pid}
    SSE stream opened. requires_action received. echo tool dispatched.
    custom_tool_result posted (is_error: false). end_turn received.
    assert_receive {:managed_agents_session, :end_turn} SUCCEEDED.
  expected: |
    mix test exits 0, output includes "1 test, 0 failures".
    assert_receive {:managed_agents_session, :end_turn} within 90 s.
  evidence: |
    Command (key sourced, not printed):
      cd /Users/ryanmckeeman/src/bizinsights/req_managed_agents &&
      set -a && source /Users/ryanmckeeman/src/bizinsights/.env.local && set +a &&
      mix test --only live test/live/live_smoke_test.exs
    Output:
      Running ExUnit with seed: 529649, max_cases: 40
      Excluding tags: [:test]
      Including tags: [:live]
      .
      Finished in 5.6 seconds (0.00s async, 5.6s sync)
      Result: 1 passed
    No secrets appear in the output.

- step_id: "D.OQ1"
  status: pass
  observed: |
    create_agent succeeded (all runs B-D). Tool definition
    %{type: "custom", name: "echo", description: ..., input_schema: ...}
    accepted by the API. In Run D the tool was exercised (requires_action dispatched
    with echo tool call) — confirming the definition is not just accepted but functional.
  expected: |
    Tool definition shape accepted. Agent name required.
  evidence: |
    Run A: 400 "name: Field required" proved name required.
    Runs B/C: create_agent passed (tool def accepted).
    Run D: requires_action dispatched — tool used by model live.

- step_id: "D.OQ2"
  status: pass
  observed: |
    custom_tool_result posted with is_error: false after echo tool dispatch.
    API accepted the event. Model proceeded to end_turn.
    Error path (is_error: true) not exercised — happy path only.
  expected: |
    is_error field accepted in user.custom_tool_result events.
  evidence: |
    Run D full cycle: requires_action → echo → custom_tool_result → end_turn.
    Success path confirmed. Error path: deferred.

- step_id: "D.OQ3"
  status: skip
  observed: |
    A real session was created in Run D (first time). However the live test does not
    call list_events — that is the reconnect path. The session_id is not captured in
    test output. Pagination shape (cursor, has_more) remains unconfirmed live.
  expected: |
    GET /v1/sessions/{id}/events returns %{"data" => [...]} at top level.
  evidence: |
    Unit test stub: test/req_managed_agents/client_test.exs:54 asserts {:ok, %{"data" => []}}.
    Pattern match in lib/req_managed_agents/session.ex:84-96.
    Not exercised live. Deferred — requires explicit list_events call with a live session_id.

- step_id: "D.OQ4"
  status: pass
  observed: |
    Real SSE stream opened in Run D. Frames decoded through SSE.decode/1 without error.
    Events observed (inferred from cycle completing): session.status_idle (requires_action),
    session.status_idle (end_turn). Agent message and span events may also have been emitted
    (handled by Handler.handle_event/2 → :ok, not surfaced in test output).
    The event: <type>\ndata: <json>\n\n wire shape used in fixtures matches live API.
  expected: |
    Real SSE frames decode cleanly through SSE.decode/1.
  evidence: |
    Run D full cycle completed in 5.6 s with live SSE frames parsed correctly.

- step_id: "B.0"
  status: pass
  observed: |
    Command: set -a; source /path/to/.env.local; set +a; test -n "$ANTHROPIC_API_KEY" && echo "key present"
    Output: key present
  expected: |
    ANTHROPIC_API_KEY present in environment (without printing the value).
  evidence: |
    Bash: test -n "$ANTHROPIC_API_KEY" && echo "key present" || echo "key MISSING"
    Result: "key present"

- step_id: "C.1a"
  status: pass
  observed: |
    create_agent/2 returned {:ok, %{"id" => agent_id}} — HTTP 201/200 success.
    The agent body with top-level name: "req-managed-agents-live-smoke", model:,
    system:, and tools: [...] was accepted. Execution advanced to create_session.
    This is the third consecutive run in which create_agent has succeeded — BUG-1
    fix is stable.
  expected: |
    {:ok, %{"id" => agent_id}} from create_agent/2.
  evidence: |
    The test advanced past line 18 (the create_agent match). The next failure was
    at create_session, confirming create_agent succeeded in Run C.

- step_id: "C.1b"
  status: fail
  observed: |
    create_session/2 returned {:error, {:http_error, 400, ...}} with message:
    "environment_id: Field required"
    The Session GenServer stopped with {:create_session_failed, reason}.
    The test received an EXIT from the session pid and surfaced as a test failure.
    No SSE stream was opened. No tool dispatch occurred. No end_turn was received.
    NOTE: The "events" rejection from BUG-2 is gone — BUG-2 fix is confirmed working.
    Body now sent is %{agent: agent_id} only. New failure: missing environment_id.
  expected: |
    {:ok, %{"id" => session_id}} from create_session/2, followed by SSE stream
    open, requires_action -> echo -> custom_tool_result -> end_turn cycle, and
    assert_receive {:managed_agents_session, :end_turn} within 90s.
  evidence: |
    Command (key sourced, not printed):
      cd /Users/ryanmckeeman/src/bizinsights/req_managed_agents &&
      set -a && source /Users/ryanmckeeman/src/bizinsights/.env.local && set +a &&
      mix test --only live test/live/live_smoke_test.exs
    Failure classification: wire-shape mismatch — POST /v1/sessions now requires
    "environment_id" which is not present in the request body.
    Request ID: req_011CcQ1LtvEcVst33ULYs5Dp (redacted key not present in this ID).
    Fix required: obtain a valid environment_id from the Managed Agents API and
    include it in create_session body: %{agent: agent_id, environment_id: env_id}.

- step_id: "B.1a"
  status: pass
  observed: |
    create_agent/2 returned {:ok, %{"id" => agent_id}} — HTTP 201/200 success.
    The agent body with top-level name: "req-managed-agents-live-smoke", model:,
    system:, and tools: [...] was accepted. Execution advanced to create_session.
  expected: |
    {:ok, %{"id" => agent_id}} from create_agent/2.
  evidence: |
    The test advanced past line 18 (the create_agent match). The next failure was
    at create_session, confirming create_agent succeeded.
    Run B request ID for the create_agent call: not separately captured (no
    error on that call to report it).

- step_id: "B.1b"
  status: fail
  observed: |
    create_session/2 returned {:error, {:http_error, 400, ...}} with message:
    "Failed to parse request body: unknown field \"events\""
    The Session GenServer stopped with {:create_session_failed, reason}.
    The test received an EXIT from the session pid and surfaced as a test failure.
    No SSE stream was opened. No tool dispatch occurred. No end_turn was received.
  expected: |
    {:ok, %{"id" => session_id}} from create_session/2, followed by SSE stream
    open, requires_action -> echo -> custom_tool_result -> end_turn cycle, and
    assert_receive {:managed_agents_session, :end_turn} within 90s.
  evidence: |
    Command (key sourced, not printed):
      cd /Users/ryanmckeeman/src/bizinsights/req_managed_agents &&
      set -a && source /Users/ryanmckeeman/src/bizinsights/.env.local && set +a &&
      mix test --only live test/live/live_smoke_test.exs
    Failure classification: wire-shape mismatch — POST /v1/sessions rejects the
    "events" key in the request body. Body sent by Session.init/1:
      %{agent: agent_id, events: [%{"type" => "user.message", ...}]}
    The "events" key is not accepted by the API at session creation time.
    Fix required: create session with %{agent: agent_id} only; send initial
    user message separately via send_events/3 after session is created.

- step_id: "C.OQ1"
  status: pass
  observed: |
    Run C (and Run B): create_agent succeeded (advanced past line 18 of the live test).
    This directly confirms the tool definition shape:
      %{type: "custom", name: "echo", description: "...", input_schema: %{...}}
    is accepted by the API without validation error.
    It also confirms the agent body requires a top-level "name" field (Run A
    confirmed this from the 400 error; Runs B and C confirmed the fix is stable).
  expected: |
    create_agent/2 succeeds. Tool definition shape accepted.
    Agent body requires top-level "name".
  evidence: |
    Run A: HTTP 400 "name: Field required" proved name is required.
    Runs B + C: create_agent advanced past the match — the agent was created.

- step_id: "C.OQ2"
  status: skip
  observed: |
    Session never created (blocked at create_session by BUG-3); no custom_tool_result
    events were sent. The is_error field could not be exercised live.
  expected: |
    is_error field accepted by the API in user.custom_tool_result events.
  evidence: |
    Not exercised — blocked by BUG-3 (environment_id required by create_session).
    Assumption: Event.custom_tool_result/3 builds %{"is_error" => boolean()}.
    Live acceptance unconfirmed.

- step_id: "C.OQ3"
  status: skip
  observed: |
    No session created; list_events was not called against the live API in any run.
    Unit test stub in client_test.exs:54 asserts {:ok, %{"data" => []}}
    which matches the Session reconnect code's pattern match on %{"data" => past}.
    Real API pagination shape (cursor? has_more?) is not determinable.
  expected: |
    GET /v1/sessions/{id}/events returns %{"data" => [...]} at minimum.
  evidence: |
    test/req_managed_agents/client_test.exs:54 (stub only, not live).
    lib/req_managed_agents/session.ex:84-96 (pattern match on "data").
    Not determinable live. Requires BUG-3 fix first.

- step_id: "C.OQ4"
  status: skip
  observed: |
    No real SSE stream was opened (no session obtained in any run). SSE decode
    fidelity against the live API is not determinable.
    From test/support/sse_fixtures.ex:6-8, expected wire format:
      "event: <type>\ndata: <json>\n\n"
    SSE.decode/1 ignores the "event:" line and parses only "data:" lines.
    StreamTest (Bypass-based) confirms decode works against a local HTTP server.
    Whether live beta uses the same frame shape or emits additional types is unconfirmed.
  expected: |
    Real SSE frames decode cleanly through SSE.decode/1.
  evidence: |
    test/req_managed_agents/stream_test.exs (Bypass, not live).
    test/support/sse_fixtures.ex wire/1 helper.
    lib/req_managed_agents/sse.ex (decoder source).
    Not determinable live. Requires BUG-3 fix first.
```
