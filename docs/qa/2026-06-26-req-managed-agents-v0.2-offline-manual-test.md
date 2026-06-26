# req_managed_agents v0.2 — Offline Manual Test

**Date:** 2026-06-26
**Branch/commit context:** HEAD (v0.2.0)
**Tester:** QA checkpoint subagent
**Environment:** darwin, Elixir 1.20.1, `mix test` baseline 44 passed 1 excluded

---

## Scope

This document covers the v0.2 surface of `req_managed_agents`: the three new archive
endpoints (`archive_agent/2`, `archive_environment/2`, `archive_session/2`), the new
list API (`list_environments/2`, `list_all_events/3` with its no-progress guard),
the Files API (`upload_file/2`, `download_file/2`, `attach_file_to_session/3`),
the synchronous one-shot `ReqManagedAgents.run_to_completion/1`, and the `:telemetry`
event bus (`[:req_managed_agents, :request|:stream|:tool|:session, ...]`).

Excluded from scope: live network calls to `api.anthropic.com`, Session/supervised-loop
behaviour, consolidation/handler logic beyond what `run_to_completion` exercises.

---

## Read this first

- **No credentials required.** All steps use `Req.Test` stubs (for unary HTTP) or
  `Bypass` local servers (for chunked SSE / pagination). No real API calls are made.
- The `:live` tag in `test_helper.exs` is `exclude: [:live]` — do not change this.
- `Req.Test` stubs are injected via `req_options: [plug: {Req.Test, <stub_name>}]`.
  They only work in the `:test` MIX_ENV.
- `Bypass` starts a real local TCP server. It is a `:test`-only dep; scripts must
  use `MIX_ENV=test mix test <file>` (not `mix run`).
- All `mix test` invocations below exclude `:live` automatically via `test_helper.exs`.

---

## Setup

```bash
cd /Users/ryanmckeeman/src/bizinsights/req_managed_agents
mix deps.get          # should already be fetched
mix compile           # clean compile
mix test              # confirm baseline: 44 passed, 1 excluded
```

No credentials or environment variables are needed for this checkpoint.

---

## A — Control Plane (archive + list_environments)

These are covered by `test/req_managed_agents/client_test.exs`.

### A.1 — `archive_agent/2` POSTs to `/v1/agents/{id}/archive`

**Method:** `mix test test/req_managed_agents/client_test.exs`
(see test: `"archive_agent/2 posts to /v1/agents/{id}/archive"`)

**Expected:** `assert {:ok, %{"archived" => true}} = Client.archive_agent(client, "ag_1")` passes.
The Req.Test stub asserts `conn.method == "POST"` and `conn.request_path == "/v1/agents/ag_1/archive"`.

### A.2 — `archive_environment/2` and `archive_session/2`

**Method:** same `client_test.exs` run.
(see test: `"archive_environment/2 and archive_session/2 hit their archive paths"`)

**Expected:** Both POST to their respective `/archive` paths; `{:ok, _}` returned for each.

### A.3 — `list_environments/2` GETs `/v1/environments`

**Method:** same `client_test.exs` run.
(see test: `"list_environments/2 GETs /v1/environments"`)

**Expected:** `{:ok, %{"data" => []}}` returned; stub asserts `conn.method == "GET"` and
`conn.request_path == "/v1/environments"`.

---

## B — Pagination (`list_all_events/3`)

These are covered by `test/req_managed_agents/client_test.exs` using Bypass servers.

### B.1 — Two-page pagination concatenates events in order

**Method:** `mix test test/req_managed_agents/client_test.exs`
(see test: `"list_all_events/3 pages through has_more using the last id as cursor"`)

**Setup:** Bypass server returns page 1 `[e1, e2]` with `has_more: true`; page 2 `[e3]`
with `has_more: false` (cursor `after_id=e2`).

**Expected:** `{:ok, [%{"id"=>"e1"}, %{"id"=>"e2"}, %{"id"=>"e3"}]}` in order.

### B.2 — No-progress guard stops after one page when cursor doesn't advance

**Method:** same `client_test.exs` run.
(see test: `"list_all_events/3 stops if a has_more page makes no progress (wrong-cursor guard)"`)

**Setup:** Bypass server always returns `[e1]` with `has_more: true` (same last id repeated).

**Expected:** `{:ok, [%{"id"=>"e1"}]}` — stops after first page, does not loop forever.

---

## C — Files API

These are covered by `test/req_managed_agents/client_test.exs` using `Req.Test`.

### C.1 — `upload_file/2` sends multipart with `files-api-2025-04-14` beta header

**Method:** `mix test test/req_managed_agents/client_test.exs`
(see test: `"upload_file/2 posts multipart to /v1/files with the files beta"`)

**Expected:** POST to `/v1/files`; `anthropic-beta: files-api-2025-04-14`; `content-type`
contains `multipart/form-data`; response `{:ok, %{"id" => "file_1"}}`.

### C.2 — `download_file/2` sends combined beta and returns raw bytes

**Method:** same `client_test.exs` run.
(see test: `"download_file/2 sends combined beta and returns raw bytes"`)

**Expected:** GET to `/v1/files/file_1/content`; `anthropic-beta: files-api-2025-04-14,managed-agents-2026-04-01`;
body decoded as raw bytes `"RAWBYTES"`; returns `{:ok, "RAWBYTES"}`.

### C.3 — `attach_file_to_session/3` POSTs resource envelope

**Method:** same `client_test.exs` run.
(see test: `"attach_file_to_session/3 posts a file resource"`)

**Expected:** POST to `/v1/sessions/s1/resources` with JSON body
`%{"type"=>"file","file_id"=>"file_1","mount_path"=>"/data/d.txt"}`; returns `{:ok, %{"id"=>"res_1"}}`.

---

## D — `run_to_completion` (synchronous one-shot)

These are covered by `test/req_managed_agents/run_to_completion_test.exs` and additionally
by the live integration script `/tmp/qa_integration_test.exs`.

### D.1 — Happy path: custom_tool_use → requires_action → end_turn

**Method (unit):** `mix test test/req_managed_agents/run_to_completion_test.exs`
(see test: `"runs synchronously to end_turn and returns events"`)

**Method (integration):** `MIX_ENV=test mix test /tmp/qa_integration_test.exs`
(test: `"D.1+E: run_to_completion end_turn with telemetry"`)

**Setup:** Bypass SSE server streams `custom_tool_use("u1","lookup",%{"q"=>"hello"})`,
then `requires_action(["u1"])`, then after 150ms `end_turn()`. Events POST handler echoes
`{:ok, "got hello"}`. Session creation returns `%{"id" => "qa-s1"}`.

**Expected:**
```elixir
{:ok, %{
  terminal: :end_turn,
  stop_reason: %{"type" => "end_turn"},
  events: [
    %{"type" => "agent.custom_tool_use", ...},
    %{"type" => "session.status_idle", "stop_reason" => %{"type" => "requires_action", ...}},
    %{"type" => "session.status_idle", "stop_reason" => %{"type" => "end_turn"}}
  ]
}}
```
Events list includes at least one `"agent.custom_tool_use"` event.

### D.2 — Timeout path returns `{:error, :timeout}`

**Method (unit):** `mix test test/req_managed_agents/run_to_completion_test.exs`
(see test: `"returns {:error, :timeout} if no terminal arrives"`)

**Method (integration):** `MIX_ENV=test mix test /tmp/qa_integration_test.exs`
(test: `"D.2: run_to_completion timeout returns {:error, :timeout}"`)

**Setup:** Bypass SSE server holds the connection open (sleeps 600ms) with no terminal event;
timeout set to 800ms.

**Expected:** `{:error, :timeout}`.

---

## E — Telemetry

Covered by `test/req_managed_agents/telemetry_test.exs` (unit) and the integration
script `/tmp/qa_integration_test.exs` (integration: runs alongside D.1).

### E.1 — `[:req_managed_agents, :request, :stop]` fires on HTTP calls

**Method (unit):** `mix test test/req_managed_agents/telemetry_test.exs`
(see test: `"Client emits a request span"`)

**Expected:** `:start` fires with `%{method: :get, path: "/v1/sessions/s1"}`;
`:stop` fires with `%{duration: _, status: 200}`.

### E.2 — Stream events: `:connected`, `:event`, `:done` fire with `session_id`

**Method (unit):** `mix test test/req_managed_agents/telemetry_test.exs`
(see test: `"Stream emits connected + event + done, merging telemetry_metadata"`)

**Expected:** Each event includes `session_id: "s1"` and the `telemetry_metadata` key
`tenant: "t1"` is merged in.

### E.3 — Integration: all six telemetry events fire in a real `run_to_completion` cycle

**Method:** `MIX_ENV=test mix test /tmp/qa_integration_test.exs`

**Expected events captured (9 total in observed run):**
- `[:req_managed_agents, :request, :stop]` — fires 3x (create_session, send_events x2)
- `[:req_managed_agents, :stream, :connected]` — `session_id: "qa-s1"`, `qa_run: "d1"`
- `[:req_managed_agents, :stream, :event]` — type `"agent.custom_tool_use"` + `"session.status_idle"` (2 events)
- `[:req_managed_agents, :stream, :done]` — `session_id: "qa-s1"`
- `[:req_managed_agents, :tool, :stop]` — `tool: "lookup"`, `is_error: false`, `session_id: "qa-s1"`
- `[:req_managed_agents, :session, :terminal]` — `terminal: :end_turn`, `session_id: "qa-s1"`

All `telemetry_metadata` keys (`qa_run: "d1"`) are merged into stream/tool/session events.

---

## Checklist

| ID  | Subsystem            | Check                                                      | Status |
|-----|----------------------|------------------------------------------------------------|--------|
| A.1 | Control plane        | `archive_agent/2` → POST `/v1/agents/{id}/archive`        | ☐ |
| A.2 | Control plane        | `archive_environment/2` + `archive_session/2` paths       | ☐ |
| A.3 | Control plane        | `list_environments/2` → GET `/v1/environments`            | ☐ |
| B.1 | Pagination           | 2-page `list_all_events` concatenates in order            | ☐ |
| B.2 | Pagination           | No-progress guard stops on cursor repeat                  | ☐ |
| C.1 | Files                | `upload_file/2` multipart + files beta header             | ☐ |
| C.2 | Files                | `download_file/2` combined beta + raw bytes               | ☐ |
| C.3 | Files                | `attach_file_to_session/3` resource envelope              | ☐ |
| D.1 | run_to_completion    | end_turn happy path returns `{:ok, %{terminal: :end_turn}}` | ☐ |
| D.2 | run_to_completion    | No-terminal path returns `{:error, :timeout}`             | ☐ |
| E.1 | Telemetry            | `:request :start/:stop` fires on HTTP calls               | ☐ |
| E.2 | Telemetry            | `:stream :connected/:event/:done` with `session_id`       | ☐ |
| E.3 | Telemetry            | Integration: all 6 event types with metadata in cycle     | ☐ |
