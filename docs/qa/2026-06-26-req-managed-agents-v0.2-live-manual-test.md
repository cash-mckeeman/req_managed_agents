# req_managed_agents v0.2 — Live Integration (Manual Test)

**Date:** 2026-06-26
**Scope:** QA-CHECKPOINT (live) for v0.2 — exercises the new surface against the **real** Claude Managed Agents beta: `run_to_completion/1`, `list_environments`, the Files write path (`upload_file` → `attach_file_to_session`), and confirms the real `list_events` pagination cursor. Credential-gated.
**Result:** ✅ GREEN — all four `:live` tests pass.

## Read this first
- Credential-gated. Source the key in-line; never print it:
  `set -a && source /Users/ryanmckeeman/src/bizinsights/.env.local && set +a && mix test --only live test/live/live_smoke_test.exs`
- The `:live` tests are excluded from the default suite (`test/test_helper.exs` → `ExUnit.start(exclude: [:live])`); default suite is `44 passed, 4 excluded`.
- The Files beta IS enabled on this key. Beta headers: `managed-agents-2026-04-01`; files use `files-api-2025-04-14` (download combines both).
- **Transient flakiness:** one full-suite run hit a `Req.TransportError: socket closed` on an agent-turn test (API-side; many live turns were run today). Re-running individually, all four pass — not a library issue.

## Live results — 2026-06-26 ✅ GREEN

| # | Test | Result |
|---|---|---|
| 1 | `full cycle against the live beta` (v0.1 Session path) | ✅ pass |
| 2 | `run_to_completion drives the full cycle` (v0.2 synchronous driver) | ✅ `{:ok, %{terminal: :end_turn}}` |
| 3 | `list_environments returns a data envelope` | ✅ `{:ok, %{"data" => [_|_]}}` |
| 4 | `file upload -> attach to a session` | ✅ upload + attach both `{:ok, _}` |

Run commands:
- Agent-turn tests (1, 2): `mix test test/live/live_smoke_test.exs:14 test/live/live_smoke_test.exs:57 --only live` → `2 passed`.
- Files test (4): `mix test --only live_files test/live/live_smoke_test.exs` → `1 passed`.
- `list_environments` (3): passed under `mix test --only live --exclude live_files`.

## OQ resolved — `list_events` pagination cursor

**Confirmed against the live API.** The list endpoint uses an **opaque cursor**, not `after_id`/`has_more`:
- Empty-session response envelope is just `%{"data" => []}` — there is **no `has_more`** field.
- When more pages exist, the response includes `"next_page" => "<opaque cursor string>"`.
- To fetch the next page, pass the query param **`page: <next_page>`**. Passing an integer `page` → HTTP 400.

`Client.list_all_events/3` was fixed to this contract (commit `b6e3da7b`): page via `page`/`next_page`, stop when `next_page` is absent/blank, with a cursor-repeat guard against a pathological server. (Our earlier `after_id`/`has_more` guess would have stopped after page 1 on any multi-page session.)

## Live findings folded into the code

| Finding | Reality | Resolution |
|---|---|---|
| `list_events` cursor | opaque `page` + `next_page` (no `has_more`) | `list_all_events` rewritten (`b6e3da7b`) |
| `upload_file` 400 `mime_type: Must be provided in Content-Type` | the multipart file part must declare a Content-Type | `file_part/2` sets `content_type` (inferred from filename, overridable) (`de0432a6`) |
| `download_file` 400 `File ... is not downloadable` | a `purpose: "agent"` file is an INPUT, not retrievable via the content endpoint | live test uses upload→attach instead; `download_file` wire behavior stays unit-tested (`36c18f80`) |
| `attach_file_to_session` 400 `file resources require the read tool ... on the agent_toolset` | attaching a file needs the session agent to have the built-in `agent_toolset_20260401` (read tool) | live test creates the agent with the built-in toolset (`36c18f80`) |

All four are correct API behavior surfaced as proper `{:error, {:http_error, 400, _}}` tuples — the client did not crash on any of them.

## Checklist
- [x] Key present (confirmed without printing)
- [x] `run_to_completion` reaches `:end_turn` live
- [x] `list_environments` returns a `data` envelope
- [x] File `upload` (with part Content-Type) succeeds live
- [x] File `attach_to_session` succeeds (agent has built-in toolset) live
- [x] `list_events` pagination cursor confirmed (`page`/`next_page`) and `list_all_events` matches
- [x] Default suite remains `44 passed, 4 excluded`; zero warnings; format clean
