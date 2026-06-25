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
   system prompt instructing it to use the `echo` tool, and one custom tool definition:
   ```elixir
   %{
     type: "custom",
     name: "echo",
     description: "Echo the user's text back. Always use this to echo.",
     input_schema: %{
       "type" => "object",
       "properties" => %{"text" => %{"type" => "string"}},
       "required" => ["text"]
     }
   }
   ```
3. Calls `ReqManagedAgents.start_session/1` with `prompt: "Please echo: hello-managed-agents"`.
4. The `Session` GenServer opens an SSE stream, receives `session.status_idle` with
   `stop_reason.type = "requires_action"`, dispatches the `echo` tool call through the
   local `Handler`, posts `user.custom_tool_result` back to the API, then waits for
   `session.status_idle` with `stop_reason.type = "end_turn"`.
5. The test asserts `{:managed_agents_session, :end_turn}` arrives within 90 seconds.

**Acceptance criterion:** `mix test` exits 0, output includes `1 test, 0 failures`.

---

## Open Questions — Observed Answers

Record concrete answers here after the live run. For each item, state whether it was
directly observed, inferred from API error messages, or not determinable in this run.

### OQ-1: Custom-tool definition fields

**Expected shape we send:**
```elixir
%{type: "custom", name: "echo", description: "...", input_schema: %{...}}
```

**Observed:**
<!-- Fill in after live run: did create_agent succeed? Any field-level error? -->
_TBD — see findings YAML below._

### OQ-2: `is_error` field in `user.custom_tool_result`

**What we send on error:**
```elixir
%{"type" => "user.custom_tool_result", "custom_tool_use_id" => id,
  "content" => [...], "is_error" => true}
```
Note: the happy-path echo test does NOT exercise the error branch. Evidence will be
inferred from whether the happy-path result (with `"is_error" => false`) is accepted
without rejection.

**Observed:**
_TBD — see findings YAML below._

### OQ-3: `GET /v1/sessions/{id}/events` pagination shape

**What our code assumes** (from `Consolidate` / `Session` reconnect path):
```elixir
{:ok, %{"data" => past}} = Client.list_events(client, session_id, %{limit: 1000})
```
Expects a `"data"` array key at the top level.

**Observed:**
_TBD — see findings YAML below._

### OQ-4: SSE frame decode fidelity

**What `ReqManagedAgents.SSE.decode/1` expects:**
- Frames delimited by `\n\n`
- Lines prefixed `data:` (space-stripped) containing JSON
- Comment lines (`:`) ignored
- Non-`data:` lines ignored

**Observed:**
_TBD — see findings YAML below._

---

## Checklist

- [ ] Key present (confirmed without printing)
- [ ] `mix deps.get` confirms deps compiled
- [ ] Live test invoked with the sourced-key command
- [ ] Exit code captured
- [ ] Test output captured (redacted of secrets)
- [ ] OQ-1 through OQ-4 answered or marked not-determinable
- [ ] Findings YAML completed below

---

## Findings YAML

```yaml
# QA-CHECKPOINT-B findings
# Status values: pass | fail | deferred | skip
```

<!-- Append findings after live execution. See report for populated YAML. -->
