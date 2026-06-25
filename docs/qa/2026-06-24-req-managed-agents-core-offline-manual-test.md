# QA Checkpoint A — `req_managed_agents` Offline Core Smoke

**Date:** 2026-06-24
**Scope:** `ReqManagedAgents.Client` config resolution, `ReqManagedAgents.SSE.decode/1`,
`ReqManagedAgents.Event` builders + `classify/1`, `ReqManagedAgents.Consolidate` — all
exercised in a live BEAM/application context with no credentials and no outbound network.

---

## Scope

This document covers the four pure/in-process Tier-1 modules of the `req_managed_agents`
library: `Client` (struct construction only), `SSE`, `Event`, and `Consolidate`. No real
Anthropic API calls are made. The `Client` HTTP round-trip evidence is obtained by running
the existing `mix test test/req_managed_agents/client_test.exs`, which wires `Req.Test`
stubs via `plug:` in `req_options` (this approach is not easily replicated inside a plain
`iex -S mix` session because `Req.Test.stub/2` depends on the process being an ExUnit
owner; the unit tests cover this scenario completely and serve as the E-section evidence).

---

## Read This First

- **No credentials required.** `Client.new/1` accepts an inline `api_key:` keyword; no
  `ANTHROPIC_API_KEY` env var is needed for sections A–D.
- **No network.** Sections A–D are pure in-process calls. Section E runs `mix test` which
  injects `Req.Test` stubs — still no outbound connections.
- **App must start.** `iex -S mix` boots `ReqManagedAgents.Application`, which starts the
  `ReqManagedAgents.StreamFinch` Finch pool. If it fails, the session cannot start.
- **Working directory.** All commands assume `cd /Users/ryanmckeeman/src/bizinsights/req_managed_agents`.
- **IEx sessions.** Steps A–D are verified in a single `iex -S mix` run; paste each
  snippet in sequence. Output is captured verbatim.

---

## Setup

```bash
cd /Users/ryanmckeeman/src/bizinsights/req_managed_agents
iex -S mix
```

Confirm the supervisor starts without errors and the `iex(1)>` prompt appears.

---

## Section A — Client struct defaults

### A.1 — `new/1` sets `base_url`, `beta`, `anthropic_version`

```elixir
c = ReqManagedAgents.Client.new(api_key: "x")
%{base_url: c.base_url, beta: c.beta, anthropic_version: c.anthropic_version}
```

**Expected:**
```
%{
  anthropic_version: "2023-06-01",
  base_url: "https://api.anthropic.com",
  beta: "managed-agents-2026-04-01"
}
```

### A.2 — `new/1` stores the supplied api_key and default timeout

```elixir
%{api_key: c.api_key, receive_timeout: c.receive_timeout}
```

**Expected:**
```
%{api_key: "x", receive_timeout: 60000}
```

---

## Section B — SSE.decode

### B.1 — one complete frame + one trailing partial

```elixir
buf = "data: {\"type\":\"a\",\"id\":\"1\"}\n\ndata: {\"type\":\"b\"}"
{events, remainder} = ReqManagedAgents.SSE.decode(buf)
{events, remainder}
```

**Expected:**
```
{[%{"id" => "1", "type" => "a"}], "data: {\"type\":\"b\"}"}
```

The decoded list has exactly one event (`type: "a"`); the partial frame is retained verbatim
as the remainder.

### B.2 — empty buffer returns empty list and empty remainder

```elixir
ReqManagedAgents.SSE.decode("")
```

**Expected:**
```
{[], ""}
```

### B.3 — comment lines are ignored; non-data lines are dropped

```elixir
buf2 = ": heartbeat\nevent: ping\ndata: {\"type\":\"c\"}\n\n"
{evs, rem} = ReqManagedAgents.SSE.decode(buf2)
{length(evs), evs |> hd() |> Map.get("type"), rem}
```

**Expected:**
```
{1, "c", ""}
```

---

## Section C — Event builders and classify/1

### C.1 — classify requires_action

```elixir
ReqManagedAgents.Event.classify(%{
  "type" => "session.status_idle",
  "stop_reason" => %{"type" => "requires_action", "event_ids" => ["e1"]}
})
```

**Expected:** `:requires_action`

### C.2 — classify end_turn

```elixir
ReqManagedAgents.Event.classify(%{
  "type" => "session.status_idle",
  "stop_reason" => %{"type" => "end_turn"}
})
```

**Expected:** `:end_turn`

### C.3 — classify terminated

```elixir
ReqManagedAgents.Event.classify(%{"type" => "session.status_terminated"})
```

**Expected:** `:terminated`

### C.4 — custom_tool_result with is_error: true

```elixir
ev = ReqManagedAgents.Event.custom_tool_result("u1", "boom", is_error: true)
ev["is_error"]
```

**Expected:** `true`

### C.5 — user_message shape

```elixir
ReqManagedAgents.Event.user_message("hello")
```

**Expected:**
```
%{"content" => [%{"text" => "hello", "type" => "text"}], "type" => "user.message"}
```

---

## Section D — Consolidate

### D.1 — unanswered_tool_uses returns only u2 (u1 has a result)

```elixir
history = [
  %{"type" => "agent.custom_tool_use", "id" => "u1", "name" => "a", "input" => %{}},
  %{"type" => "agent.custom_tool_use", "id" => "u2", "name" => "b", "input" => %{}},
  %{"type" => "user.custom_tool_result", "custom_tool_use_id" => "u1"}
]
ReqManagedAgents.Consolidate.unanswered_tool_uses(history) |> Enum.map(& &1["id"])
```

**Expected:** `["u2"]`

### D.2 — dedupe drops already-seen ids

```elixir
batch = [%{"id" => "e1", "v" => 1}, %{"id" => "e2", "v" => 2}, %{"id" => "e3", "v" => 3}]
seen = MapSet.new(["e1"])
{fresh, seen2} = ReqManagedAgents.Consolidate.dedupe(batch, seen)
{Enum.map(fresh, & &1["id"]), MapSet.to_list(seen2) |> Enum.sort()}
```

**Expected:**
```
{["e2", "e3"], ["e1", "e2", "e3"]}
```

### D.3 — dedupe of a fully-seen batch returns empty

```elixir
batch2 = [%{"id" => "e2"}, %{"id" => "e3"}]
{fresh2, _} = ReqManagedAgents.Consolidate.dedupe(batch2, seen2)
fresh2
```

**Expected:** `[]`

---

## Section E — Client HTTP round-trip (Req.Test stubs via mix test)

The `Req.Test.stub/2` mechanism requires the calling process to be the ExUnit test-case
owner, which means it cannot be driven cleanly from a plain `iex -S mix` session. The
client tests in `test/req_managed_agents/client_test.exs` cover all four cases:
`create_session/2` (201 body), `send_events/3`, `list_events/3`, and a 400 non-2xx error.
Run them as the E-evidence:

```bash
mix test test/req_managed_agents/client_test.exs --seed 0
```

**Expected:**
```
.....
Finished in 0.XXs (0.XXs async, 0.00s sync)
5 passed
```

(Five dots, zero failures — `client_test.exs` has 5 tests: new/1 defaults, create_session, send_events, list_events, non-2xx error.)

---

## Checklist

| ID   | Check                                                                 | Pass/Fail |
|------|-----------------------------------------------------------------------|-----------|
| A.1  | `Client.new` sets correct `base_url`, `beta`, `anthropic_version`    |           |
| A.2  | `Client.new` stores `api_key` and `receive_timeout: 60000`           |           |
| B.1  | `SSE.decode` splits one complete frame + retains partial remainder    |           |
| B.2  | `SSE.decode("")` returns `{[], ""}`                                   |           |
| B.3  | `SSE.decode` ignores comment and non-data lines                       |           |
| C.1  | `Event.classify` maps `requires_action` → `:requires_action`         |           |
| C.2  | `Event.classify` maps `end_turn` → `:end_turn`                       |           |
| C.3  | `Event.classify` maps `session.status_terminated` → `:terminated`    |           |
| C.4  | `Event.custom_tool_result` with `is_error: true` sets `"is_error"`   |           |
| C.5  | `Event.user_message` produces correct wire shape                     |           |
| D.1  | `Consolidate.unanswered_tool_uses` returns only unanswered `u2`      |           |
| D.2  | `Consolidate.dedupe` drops seen id, grows seen-set                   |           |
| D.3  | `Consolidate.dedupe` of fully-seen batch returns `[]`                |           |
| E.1  | `mix test client_test.exs` — 4 Req.Test-stubbed cases pass           |           |
