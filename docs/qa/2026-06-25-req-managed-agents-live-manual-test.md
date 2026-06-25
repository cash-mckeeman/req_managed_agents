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
   `%{agent: agent_id, events: [user_message]}`.
4. The `Session` GenServer opens an SSE stream, receives `session.status_idle` with
   `stop_reason.type = "requires_action"`, dispatches the `echo` tool call through the
   local `Handler`, posts `user.custom_tool_result` back to the API, then waits for
   `session.status_idle` with `stop_reason.type = "end_turn"`.
5. The test asserts `{:managed_agents_session, :end_turn}` arrives within 90 seconds.

**Acceptance criterion:** `mix test` exits 0, output includes `1 test, 0 failures`.

---

## Run History

### Run A — 2026-06-25 (initial)

**Result:** FAIL — exit code 2

**Error:** `POST /v1/agents` → HTTP 400 `"name: Field required"`

**Root cause:** `create_agent/2` call body lacked a top-level `"name"` field for the
agent itself. The fix was to add `name: "req-managed-agents-live-smoke"` to the
`create_agent` map in `test/live/live_smoke_test.exs`.

**Classification:** wire-shape mismatch at `create_agent`.

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

**Observed (accumulated across Run A + Run B):**

Run A: `POST /v1/agents` was rejected with HTTP 400 `"name: Field required"` referring
to the **agent-level** `name` field (not the tool's `name`). The live test was fixed
to include `name: "req-managed-agents-live-smoke"` in the agent body.

Run B: `create_agent/2` **succeeded** — `{:ok, %{"id" => agent_id}}` was returned and
execution advanced to `create_session`. This directly confirms:

- The agent body shape `%{name:, model:, system:, tools: [...]}` is accepted.
- The top-level agent `name` field is **required** by the API (confirmed from Run A error).
- The tool definition shape `%{type: "custom", name:, description:, input_schema:}` was
  accepted without any validation error from the API — the request passed agent-creation
  validation and the agent was created successfully.

**Conclusion:** Both findings confirmed live:
1. Agent body requires a top-level `name` string (the agent's display name).
2. Tool definition fields `%{type: "custom", name:, description:, input_schema:}` are
   accepted — directly confirmed in Run B.

**Source:** inferred from Run A error + directly observed from Run B progression.

---

### OQ-2: `is_error` field in `user.custom_tool_result`

**What we send on error:**
```elixir
%{"type" => "user.custom_tool_result", "custom_tool_use_id" => id,
  "content" => [...], "is_error" => true}
```

**Observed:** Session creation failed in Run B before any SSE stream was opened or
any `custom_tool_result` event was sent. Neither the happy-path (`is_error: false`)
nor the error-path (`is_error: true`) branch was exercised live.

**Status:** not exercised live — blocked by the `create_session` wire-shape mismatch.
Once `create_session` is fixed (remove `events:` from body, send initial message via
`send_events` separately), this question becomes testable.

**Assumption:** `Event.custom_tool_result/3` builds `%{"is_error" => boolean()}`.
Live acceptance is unconfirmed. Mark: **success-path and error-path both unconfirmed**.

---

### OQ-3: `GET /v1/sessions/{id}/events` pagination shape

**What our code assumes** (from `Consolidate` / `Session` reconnect path):
```elixir
{:ok, %{"data" => past}} = Client.list_events(client, session_id, %{limit: 1000})
```
Expects a `"data"` array key at the top level.

**Observed:** No session was created (blocked at `create_session`), so `list_events`
was not called against the live API in either run.

Run B confirms `create_agent` now succeeds, so once the `create_session` body is
corrected, an actual session_id will be available and `list_events` can be exercised.

**Status:** not determinable in this run. The unit test stub in
`test/req_managed_agents/client_test.exs` line 54 confirms we assert
`{:ok, %{"data" => []}}` from the stub, matching the code's `%{"data" => past}`
pattern match. Real API cursor/`has_more` fields: not confirmed.

---

### OQ-4: SSE frame decode fidelity

**What `ReqManagedAgents.SSE.decode/1` expects:**
- Frames delimited by `\n\n`
- Lines prefixed `data:` (space-stripped) containing JSON
- Comment lines (`:`) ignored
- Non-`data:` lines (including `event:` lines) ignored

**Observed:** No real SSE stream was opened in either run (blocked before
`start_consumer/1` in `Session`). SSE decode fidelity against the live API remains
unconfirmed.

From `test/support/sse_fixtures.ex`: expected wire format is
`"event: <type>\ndata: <json>\n\n"`. `SSE.decode/1` deliberately ignores the `event:`
line and reads only `data:` — consistent with the fixture shape. The Bypass-based
`StreamTest` confirms decode works against a local HTTP server emitting the same format.

Whether the live beta uses this exact frame shape, emits additional event types
(e.g. `"ping"`), or uses different line endings remains unconfirmed.

**Status:** not determinable in this run. OQ-4 becomes testable only after both
`create_agent` + `create_session` succeed.

---

## Identified Bugs (Live Discoveries)

### BUG-1: Agent body missing top-level `name` field (FIXED in live test)
- **Where:** `test/live/live_smoke_test.exs` (create_agent call, pre-fix)
- **Symptom:** HTTP 400 `"name: Field required"` on `POST /v1/agents`
- **Fix applied:** `name: "req-managed-agents-live-smoke"` added to agent body in the live test.
- **Note:** `examples/local_tool_example.exs` already had `name: "billing-support"`. The
  `Session.init/1` generic path doesn't include a name — but `create_agent` is called
  by the caller, not Session, so this is caller-side.

### BUG-2: Session create body includes unknown `events` field (OPEN — not fixed)
- **Where:** `lib/req_managed_agents/session.ex` lines 62–65
- **Symptom:** HTTP 400 `"Failed to parse request body: unknown field \"events\""` on
  `POST /v1/sessions`
- **Root cause:** `Session.init/1` bundles the initial user message inside the create_session
  body as `%{agent: agent_id, events: [user_message]}`. The live API does not accept an
  `events` key at session-creation time.
- **Expected fix:** Create the session with `%{agent: agent_id}` only (no `events`), then
  immediately call `Client.send_events/3` with the initial user message before opening the
  SSE stream. The test stub in `client_test.exs:31` uses `%{agent: "agent_1", events: []}`,
  which would also need updating if this mock is changed.
- **Blocker for:** OQ-2, OQ-3, OQ-4, and the full `end_turn` cycle.

---

## Checklist

- [x] Key present (confirmed without printing — `test -n "$ANTHROPIC_API_KEY"` returned "key present")
- [x] Live test invoked with the sourced-key command (Run B)
- [x] Exit code captured (exit code 2 — test failure)
- [x] Test output captured (verbatim above, no secrets in output)
- [x] OQ-1 partially answered: tool definition fields confirmed accepted; agent `name` confirmed required
- [ ] OQ-2 not yet determinable (create_session blocked)
- [ ] OQ-3 not yet determinable (no session id obtained)
- [ ] OQ-4 not yet determinable (no SSE stream opened)
- [x] BUG-1 documented (fixed in test); BUG-2 documented (open, blocks full cycle)

---

## Findings YAML

```yaml
# QA-CHECKPOINT-B findings
# Status values: pass | fail | deferred | skip
# Run B results below (supersedes Run A)

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

- step_id: "B.OQ1"
  status: pass
  observed: |
    Run B: create_agent succeeded (advanced past line 18 of the live test).
    This directly confirms the tool definition shape:
      %{type: "custom", name: "echo", description: "...", input_schema: %{...}}
    is accepted by the API without validation error.
    It also confirms the agent body requires a top-level "name" field (Run A
    confirmed this from the 400 error; Run B confirmed the fix works).
  expected: |
    create_agent/2 succeeds. Tool definition shape accepted.
    Agent body requires top-level "name".
  evidence: |
    Run A: HTTP 400 "name: Field required" proved name is required.
    Run B: create_agent advanced past the match — the agent was created.

- step_id: "B.OQ2"
  status: skip
  observed: |
    Session never created (blocked at create_session); no custom_tool_result
    events were sent. The is_error field could not be exercised live.
  expected: |
    is_error field accepted by the API in user.custom_tool_result events.
  evidence: |
    Not exercised — blocked by BUG-2 (create_session body shape mismatch).
    Assumption: Event.custom_tool_result/3 builds %{"is_error" => boolean()}.
    Live acceptance unconfirmed.

- step_id: "B.OQ3"
  status: skip
  observed: |
    No session created; list_events was not called against the live API.
    Unit test stub in client_test.exs:54 asserts {:ok, %{"data" => []}}
    which matches the Session reconnect code's pattern match on %{"data" => past}.
    Real API pagination shape (cursor? has_more?) is not determinable in this run.
  expected: |
    GET /v1/sessions/{id}/events returns %{"data" => [...]} at minimum.
  evidence: |
    test/req_managed_agents/client_test.exs:54 (stub only, not live).
    lib/req_managed_agents/session.ex:84-96 (pattern match on "data").
    Not determinable live in this run. Requires BUG-2 fix first.

- step_id: "B.OQ4"
  status: skip
  observed: |
    No real SSE stream was opened (no session obtained). SSE decode fidelity
    against the live API is not determinable.
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
    Not determinable live in this run. Requires BUG-2 fix first.
```
