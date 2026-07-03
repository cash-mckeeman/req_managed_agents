# QA-CHECKPOINT B — CMA Artifacts (PR MIM-66)

**Date:** 2026-07-03
**Tester:** QA-tester subagent (automated manual execution)
**Commits under test:** 03ed4c9e + 1543c628 + e69c52a6
**Worktree:** `.claude/worktrees/rma-030-artifacts`
**Scope:** `Client.list_files/2` + `delete_file/2` (combined betas, `scope_id` scoping);
`ReqManagedAgents.Artifacts` behaviour + facade (`{impl, store}` dispatch);
`Artifacts.ClaudeFiles` store (session-scoped list → `%Artifact{}`; fetch/delete
newest-by-`created_at`; put = upload + attach). Composed with PR 1's `%SessionInfo{}`
threading to `handle_tool_call/4`.

---

## Setup

All commands run from the worktree root. One scratch file
(`test/qa_b_scratch.exs`) was authored, executed, and deleted before committing.

**Baseline:** `mix test` before scratch creation:

```
$ mix test 2>&1 | tail -2
Finished in 16.0 seconds (14.1s async, 1.8s sync)
Result: 219 passed, 6 excluded
```

## Execution method

All scenarios ran as real ExUnit tests (`async: false`) in
`test/qa_b_scratch.exs`, executed scenario-by-scenario and then as one suite:

```
$ mix test test/qa_b_scratch.exs --seed 0
Finished in 14.1 seconds (0.00s async, 14.1s sync)
Result: 20 passed
```

Client-layer scenarios stubbed HTTP with `Req.Test`
(`req_options: [plug: {Req.Test, StubName}]`); facade/store scenarios injected a
stub `client_mod` (the seam `ClaudeFiles.store/3` exposes); the composed
Scenario 1 used a real `%ReqManagedAgents.Client{}` with the `Req.Test` plug
playing the Files API end-to-end.

---

## Scenario 1 — The composed release story (GH #29/#30 fetch-output workflow)

**Motivation:** No unit test composes session → tool → `%SessionInfo{}` → store →
bytes. This is the release's headline path: a handler inside a running
`Session.run/2` uses its `SessionInfo.session_id` to build a `ClaudeFiles` store
and fetch a file "the agent wrote".

**Setup:**
- `QAB.Provider` — request_response fake whose `open/2` puts
  `session_id: "qa-sess-42"` on the conn. Its `poll_turn/2` also forwards the
  `{:resume, results}` payload back to the test pid so the *wire tool result*
  is assertable.
- `QAB.FetchHandler.handle_tool_call/4` — on `"fetch_report"`, builds
  `{ClaudeFiles, ClaudeFiles.store(client, info.session_id)}` from the
  `%SessionInfo{}` it received and calls `Artifacts.fetch(store, "report.md")`;
  returns `{:ok, bytes}`.
- The client is the REAL `ReqManagedAgents.Client`, stubbed at the HTTP layer:
  `Client.new(api_key: "sk-test", req_options: [plug: {Req.Test, QABFilesApi}])`.
  The stub plug plays the Files API: `GET /v1/files` (asserts
  `scope_id == "qa-sess-42"` AND both beta headers) returns one `report.md`
  record; `GET /v1/files/file_qa_1/content` returns raw `"REPORT_BYTES"`.
- Turn script: `[tool fetch_report, requires_action]` → `[end_turn]`.

**Ownership note (real gotcha, documented for consumers):** the tool handler runs
in a `Task` inside the Session GenServer, which is started via `GenServer.start`
— there is no `$callers` chain back to the test process, so a *private*-mode
`Req.Test` stub raises "cannot find mock/stub". The test must switch the stub to
shared mode:

```elixir
Req.Test.set_req_test_to_shared(%{})
on_exit(fn -> Req.Test.set_req_test_to_private(%{}) end)
```

With that in place the scenario runs green. (First execution of this scenario
used Bypass — a real HTTP server — and also passed; it was converted to the
`Req.Test` plug form required by the checkpoint spec.)

**Assertions (all in one test):**
1. Stub saw `GET /v1/files?scope_id=qa-sess-42` with
   `anthropic-beta: files-api-2025-04-14,managed-agents-2026-04-01` — the
   handler's store really scoped the list by THAT session's id. ✅
2. Handler received `{:ok, "REPORT_BYTES"}` from `Artifacts.fetch` (bytes came
   from the stubbed download endpoint). ✅
3. The provider's resume input carried
   `%ToolResult{tool_use_id: "tu_1", text: "REPORT_BYTES", is_error: false}` —
   the fetched bytes made it into the tool result on the wire. ✅
4. `result.session_id == "qa-sess-42"`, `result.terminal == :end_turn`. ✅

```
$ mix test test/qa_b_scratch.exs --seed 0 --only describe:"Scenario 1 — composed release story"
Finished in 0.1 seconds (0.00s async, 0.1s sync)
Result: 1 passed, 18 excluded
```

**Result: ✅**

---

## Scenario 2 — Header/param contract against the real Client (Req.Test)

Direct `Client` calls through the `Req.Test` plug, asserting on the received
`Plug.Conn`.

### 2.1 — Scoped list: BOTH betas + `scope_id` query

`Client.list_files(c, params: %{scope_id: "sess_qa"})` →
`GET /v1/files?scope_id=sess_qa`; `anthropic-beta` contains both
`files-api-2025-04-14` and `managed-agents-2026-04-01`. **✅**

### 2.2 — delete_file: DELETE with both betas

`Client.delete_file(c, "f_del")` → `DELETE /v1/files/f_del`; both betas
present; `{:ok, %{"deleted" => true}}` returned. **✅**

### 2.3 — Unscoped list: no query string; betas STILL combined

`Client.list_files(c)` → `GET /v1/files` with `conn.query_string == ""`.

Probed beyond the unit suite (whose "no query" test asserts only the query
string, not headers): the unscoped call ALSO sends the combined
`files-api-2025-04-14,managed-agents-2026-04-01` beta pair. This matches the
code comment in `client.ex` ("harmless when unscoped") — intentional, verified.
**✅**

```
$ mix test test/qa_b_scratch.exs --seed 0 --only describe:"Scenario 2 — header/param contracts"
Result: 3 passed, 16 excluded
```

**Result: ✅ (3/3)**

---

## Scenario 3 — Duplicate-name semantics through the FACADE

All calls go through `ReqManagedAgents.Artifacts` with
`{ClaudeFiles, ClaudeFiles.store(:fake_client, "sess_qa", client_mod: QAB.Stub)}`
— exercising the `{impl, store}` dispatch, not the impl directly. The stub's
list fixture: `report.md` at `2026-07-01` (`file_old`), `report.md` at
`2026-07-03` (`file_new`), `data.csv` at `2026-07-02` (`file_z`).

### 3.1 — list returns ALL duplicates

`Artifacts.list/1` → 3 artifacts, two named `report.md`; the stub received
`params: %{scope_id: "sess_qa"}`. **✅**

### 3.2 — fetch picks newest `created_at`

`Artifacts.fetch(store, "report.md")` → `{:ok, "bytes:file_new"}`; stub saw
`{:download, "file_new"}`. **✅**

### 3.3 — delete picks newest `created_at`

`Artifacts.delete(store, "report.md")` → `:ok`; stub saw
`{:delete, "file_new"}`. **✅**

### 3.4 — EDGE: two files with IDENTICAL `created_at`

Fixture: `id_alpha` and `id_beta`, both `dup.txt` at `2026-07-03T00:00:00Z`.

**Observed:** no crash; `Artifacts.fetch` returned `"bytes:id_alpha"` — the
FIRST record in the API response order wins. `Enum.sort_by/3` is a stable sort,
so among equal keys the server's list order decides. Deterministic given a fixed
server ordering; effectively server-defined from the caller's perspective.
Documented behavior, no code change required. **✅ (documented)**

### 3.5 — EDGE: record with `created_at: nil`

Fixture: `file_ts` (`"2026-07-01…"`) and `file_nil` (`created_at: nil`), both
`rep.md`.

**Observed:** no crash. Erlang term ordering places `nil` (an atom) *below* any
binary, so under `:desc` the string-timestamped record ranks first —
`Artifacts.fetch` chose `file_ts`. A nil-timestamped record is treated as
oldest. Well-defined, sensible, does not raise. **✅ (documented)**

### 3.6 — Empty `data`

`{:ok, %{"data" => []}}` from the client → `Artifacts.list` returns
`{:ok, []}`; `fetch`/`delete` of any name → `{:error, :not_found}` (covered in
Scenario 5). **✅**

### 3.7 — PROBE: 200 body MISSING the `"data"` key

Stub returns `{:ok, %{}}` (an HTTP-200 body with no `"data"` key — e.g. a
malformed or unexpected-shape response).

**Observed:** `Artifacts.list(store)` returns `{:ok, %{}}` — the `with` pattern
`{:ok, %{"data" => files}}` does not match, and the non-matching value is
returned VERBATIM. The caller receives `{:ok, map}` where the
`@callback list … :: {:ok, [Artifact.t()]} | {:error, term()}` contract promises
a list. The same short-circuit exists in `newest/3`, so `fetch`/`delete` would
likewise leak `{:ok, %{}}` where `{:ok, binary()}` / `:ok` is promised. No
crash, but a downstream `Enum.map(artifacts, …)` in consumer code would raise
far from the cause. **→ FINDING 1 (code_bug, low)**

### 3.8 — `Artifact.raw` fidelity

A record carrying an extra vendor field (`"extra_vendor_field" => "keep_me"`)
maps to `%Artifact{name: "raw_test.txt", size: 42, ref: "f_raw", raw: <exact
input map>}` — `raw` is the byte-identical provider record including unknown
fields. **✅**

```
$ mix test test/qa_b_scratch.exs --seed 0 --only describe:"Scenario 3 — duplicate-name semantics"
Result: 8 passed, 12 excluded
```

**Result: ✅ (8/8 executed; 3.7 surfaced Finding 1)**

---

## Scenario 4 — `put` → upload + attach through the facade

### 4.1 — Default mount path

`Artifacts.put(store, "report.csv", "a,b,c")` → stub saw
`{:upload, %{purpose: "agent", file: {"report.csv", "a,b,c"}}}` then
`{:attach, "sess_qa", %{file_id: "file_up", mount_path: "/data/report.csv"}}`;
returned `:ok`. Order verified via mailbox order. **✅**

### 4.2 — Custom mount path

`Artifacts.put(store, "report.csv", "a,b,c", mount_path: "/inputs/report.csv")`
→ attach carried `mount_path: "/inputs/report.csv"`. **✅**

### 4.3 — PROBE: attach failure (the documented upload leak)

Stub: upload succeeds (`{:ok, %{"id" => "file_up"}}`), attach returns
`{:error, {:http_error, 403, %{"error" => "forbidden"}}}`.

**Observed:**
- `{:upload, …}` WAS received — the file was uploaded (quota consumed) before
  the attach failed. No rollback/delete is attempted. This is the
  DOCUMENTED-EXPECTED upload leak per the design review.
- `Artifacts.put` returned the attach error verbatim:
  `{:error, {:http_error, 403, %{"error" => "forbidden"}}}` — passes through
  untouched. **✅ (matches documented expectation)**

### 4.4 — PROBE: path traversal in the default mount path

`Artifacts.put(store, "../evil.sh", "#!/bin/sh")`:

```
traversal mount_path sent to attach: /data/../evil.sh
```

**Observed:** the default `"/data/" <> name` concatenation performs NO
sanitization; a relative name escapes `/data/` (resolves to `/evil.sh`).
The library forwards it verbatim and defers validation to the server. `name`
typically comes from the trusted caller, but callers deriving names from
model/agent output would pass traversal through silently.
**→ FINDING 2 (doc_issue, low)**

```
$ mix test test/qa_b_scratch.exs --seed 0 --only describe:"Scenario 4 — put: upload then attach"
Result: 4 passed, 16 excluded
```

**Result: ✅ (4/4)**

---

## Scenario 5 — Error paths

### 5.1 — `:not_found` on fetch

Name absent from the scoped list → `Artifacts.fetch(store, "nope.txt")` →
`{:error, :not_found}`. **✅**

### 5.2 — `:not_found` on delete

`Artifacts.delete(store, "nope.txt")` → `{:error, :not_found}`; no
`delete_file` call reached the client. **✅**

### 5.3 — HTTP 429 passes through as `{:error, {:http_error, 429, _}}`

Real `Client` + `Req.Test` stub always answering 429.

- Direct: `Client.list_files(c, params: %{scope_id: "sess_1"})` →
  `{:error, {:http_error, 429, %{"error" => "rate_limited"}}}`. **✅**
- Through the facade: `Artifacts.list({ClaudeFiles, store})` with the same
  client → the identical tuple, untouched by the store or facade. **✅**

**BUT — observed retry behavior before the error surfaced:**

```
[warning] retry: got response with status 429, will retry in 1000ms, 3 attempts left
[warning] retry: got response with status 429, will retry in 2000ms, 2 attempts left
[warning] retry: got response with status 429, will retry in 4000ms, 1 attempt left
```

Each `list_files` 429 took **~7 s** (4 attempts) before returning. `file_req/4`
sets no `:retry` option, so Req's DEFAULT `:safe_transient` policy applies —
it retries idempotent-safe methods (GET) on 429/5xx but NOT DELETE/POST.

### 5.4 — PROBE: retry asymmetry across files endpoints

Counter-instrumented stub:

```
delete_file 429: 1 attempt(s), 0ms
```

`delete_file` (DELETE) surfaced the 429 immediately — 1 attempt. So within the
files endpoint family: `list_files`/`download_file` (GET) retry 3 times under
the implicit default; `delete_file`/`upload_file` do not retry at all. Contrast
with the JSON endpoints (`req/2`), which EXPLICITLY set
`retry: :transient, max_retries: 3` — retrying ALL methods including POST and
DELETE. Consequences:

- A rate-limited `Artifacts.fetch` (list GET + download GET) can block
  **~14 s** before erroring — inside a tool handler this eats into the session
  turn budget.
- `put` is internally inconsistent: its upload (files POST, no retry) fails
  fast while its attach (JSON POST, `:transient`) retries — and a transient
  upload failure that a retry would have absorbed instead surfaces (and a
  retried-then-failed attach still leaks the upload, compounding 4.3).
- The retry posture of the files endpoints is implicit (Req default) rather
  than chosen, unlike every other endpoint in the module.
  **→ FINDING 3 (code_bug, low)**

```
$ mix test test/qa_b_scratch.exs --seed 0 --only describe:"Scenario 5 — error paths"
Result: 4 passed, 16 excluded   (14.1s — the 429 retries dominate)
```

**Result: ✅ (4/4; 5.3/5.4 surfaced Finding 3)**

---

## Final validation

Scratch file deleted, then:

```
$ mix test 2>&1 | tail -2
Finished in 16.0 seconds (14.1s async, 1.8s sync)
Result: 219 passed, 6 excluded

$ mix format --check-formatted
(clean — exit 0)
```

**Result: ✅ — suite green, formatting clean, no lib/ modifications.**

---

## Checklist

| Step | Scenario                                                                        | Result |
|------|---------------------------------------------------------------------------------|--------|
| 1    | Composed story: Session → SessionInfo → ClaudeFiles → fetch → bytes in ToolResult | ✅   |
| 2.1  | Scoped list sends BOTH betas + `scope_id`                                       | ✅     |
| 2.2  | delete_file sends both betas                                                     | ✅     |
| 2.3  | Unscoped list: no query (betas still combined — intentional)                     | ✅     |
| 3.1  | Facade list returns all duplicates                                               | ✅     |
| 3.2  | Facade fetch picks newest `created_at`                                           | ✅     |
| 3.3  | Facade delete picks newest `created_at`                                          | ✅     |
| 3.4  | EDGE identical `created_at`: stable sort — server list order wins, no crash      | ✅     |
| 3.5  | EDGE `created_at: nil`: no crash — nil sorts as oldest                           | ✅     |
| 3.6  | Empty data → `{:ok, []}`                                                         | ✅     |
| 3.7  | PROBE missing `"data"` key → `{:ok, %{}}` leaks (spec violation)                 | ✅ F1  |
| 3.8  | `Artifact.raw` is the exact provider record                                      | ✅     |
| 4.1  | put: upload → attach at `/data/<name>`                                           | ✅     |
| 4.2  | put: custom `mount_path` honored                                                 | ✅     |
| 4.3  | put: attach failure — error passes through; upload leak as documented            | ✅     |
| 4.4  | PROBE traversal name → unsanitized `/data/../evil.sh` forwarded                  | ✅ F2  |
| 5.1  | fetch missing name → `{:error, :not_found}`                                      | ✅     |
| 5.2  | delete missing name → `{:error, :not_found}`                                     | ✅     |
| 5.3  | 429 → `{:error, {:http_error, 429, _}}` untouched (direct + facade)              | ✅     |
| 5.4  | PROBE retry asymmetry: files GET retries ~7s; DELETE/POST don't                  | ✅ F3  |

20/20 executed steps passed; 3 findings raised for triage.

---

## Findings

### FINDING 1 — code_bug (low): non-matching 200 body leaks `{:ok, map}` through the Artifacts contract

`ClaudeFiles.list/2` and `newest/3` use
`with {:ok, %{"data" => files}} <- client_mod.list_files(…)`. A 200 response
whose body lacks `"data"` short-circuits the `with` and is returned VERBATIM:
`Artifacts.list` yields `{:ok, %{}}` where the behaviour promises
`{:ok, [Artifact.t()]}`; `fetch`/`delete` likewise. No crash in the library, but
consumers matching `{:ok, artifacts}` then enumerating will raise far from the
cause. Suggested fix: add an `other -> {:error, {:unexpected_response, other}}`
else-clause (or match `{:ok, %{"data" => files}} when is_list(files)`).
File: `lib/req_managed_agents/artifacts/claude_files.ex` (`list/2`, `newest/3`).

### FINDING 2 — doc_issue (low): default `mount_path` is unsanitized string concatenation

`put`'s default mount path is `"/data/" <> name` — a name containing `../`
(or an absolute-looking segment) escapes `/data/` and is forwarded to
`attach_file_to_session` verbatim (verified: `"../evil.sh"` →
`/data/../evil.sh`). Validation is implicitly delegated to the server. Fine for
trusted callers, but worth one sentence in the `ClaudeFiles` moduledoc (and/or
`Artifacts.put/4` doc) warning against deriving `name` from untrusted
model/agent output; a `Path.basename/1` guard would also be cheap.

### FINDING 3 — code_bug (low): files endpoints have an implicit, asymmetric retry posture

`file_req/4` sets no `:retry`, so Req's default `:safe_transient` applies:
`list_files`/`download_file` (GET) silently retry 429/5xx 3 times
(~7 s each; a rate-limited `Artifacts.fetch` can block ~14 s inside a tool
handler), while `delete_file`/`upload_file` fail fast (verified: 1 attempt,
<1 ms). Every other endpoint in the module explicitly sets
`retry: :transient, max_retries: 3` (all methods). Net effect: `put`'s two legs
disagree (upload never retries, attach always does — a transiently failed
upload that one retry would absorb instead surfaces, and a retried-then-failed
attach still leaks the upload per 4.3). The 429 error SHAPE does pass through
untouched — the finding is the unchosen/inconsistent retry policy, not the
error mapping. Suggested fix: set `:retry` explicitly in `file_req/4` (either
`:transient` for parity or `false` + document).
File: `lib/req_managed_agents/client.ex` (`file_req/4`).

### Test-gap notes (for the unit suite, no code change)

- `client_test.exs` "list_files without params" asserts only the empty query
  string, not that the combined betas are still sent (Step 2.3 covers it here).
- No unit test composes SessionInfo → ClaudeFiles → fetch (Scenario 1); worth
  one integration test since it is the release's headline workflow. NOTE for
  authors: the `Req.Test` stub must be put in SHARED mode
  (`Req.Test.set_req_test_to_shared/1`) — the tool Task inside the Session
  GenServer has no `$callers` chain to the test process.
- Identical-`created_at` and nil-`created_at` edges (3.4/3.5) are undocumented
  and untested in the unit suite; both are safe but the stable-sort tie rule
  deserves a one-line test to pin it.
