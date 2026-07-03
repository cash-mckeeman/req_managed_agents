# RMA 0.3.0 — Session Artifacts Design (MIM-65 / MIM-66 / MIM-67)

**Date:** 2026-07-03
**Status:** Approved design (brainstorm complete)
**Linear:** project "RMA 0.3.0 — session artifacts" — MIM-65, MIM-66, MIM-67. GitHub: closes #29, #30.
**Release thesis:** an agent that writes a deliverable into its session sandbox must be
retrievable from the host, on either backend — one artifacts vocabulary, provider-native
mechanics underneath. MIM-68 (outcomes/user-event kickoffs) is explicitly the next release.

---

## Verified constraints

1. **CMA Files API** (Anthropic): `GET /v1/files` (supports session scoping via `scope_id`)
   and `DELETE /v1/files/{id}` exist but are absent from `ReqManagedAgents.Client`, which has
   only `upload_file/2`, `download_file/2`, `attach_file_to_session/3`. File ids are minted
   server-side and never surface inside the sandbox — **the model can only reference a file
   by name**, so a session-scoped list is the only id-discovery path. Files endpoints use
   `file_headers/2` (own beta header, `files-api-2025-04-14`); the session-scoped list needs
   the managed-agents beta as well (same combined-header pattern as `download_file/2` — the
   plan pins exact headers from the code).
2. **AgentCore environment** (verified 2026-07-03, devguide `harness-environment`):
   Create/UpdateHarness accept `environment.agentCoreRuntimeEnvironment` (carrying
   `filesystemConfigurations` — `sessionStorage` (per-`runtimeSessionId`, **no VPC**),
   `efsAccessPoint` (**VPC**), `s3FilesAccessPoint` (**VPC**, bidirectional S3 sync) — plus
   `networkConfiguration`, `containerConfiguration`) and a sibling `environmentVariables`
   field. `UpdateHarness` replaces the whole `filesystemConfigurations` list. RMA's
   `create_harness/2` currently sends neither field.
3. **`InvokeAgentRuntimeCommand`** (data plane): `agentRuntimeArn` + `runtimeSessionId` +
   `body: {"command": …}` → event stream of `contentDelta` (`stdout`/`stderr`) and
   `contentStop` (`exitCode`). Runs as root in the microVM; IAM-gated. Base image has
   python3 + bash. Not in RMA's client; not in the CI IAM policy.
4. **Session identity plumbing:** Claude conn already carries `session_id`; Bedrock conn
   carries `sid` (caller-supplied). `Session` passes only the static `opts[:context]` to
   tools; `%SessionResult{}` has no `session_id`.
5. **Provisioner spec-hash:** `harness_name/2` hashes the **whole spec map**
   (`term_to_binary(spec, [:deterministic])`) — anything added as a spec field automatically
   distinguishes cached harnesses; anything passed as an opt escapes the hash.
6. `Client.Behaviour` exists (`lib/req_managed_agents/client/behaviour.ex`) — new Client
   functions must be added there (mock seam).

## Decisions (from the brainstorm)

- **D1 — Scope:** all of MIM-65 (both `environment` pass-through and the command API),
  MIM-66 (primitives + convenience), MIM-67. One branch, one plan, dependency-ordered
  (67 → 66 → 65 → Artifacts → docs/canary/release); one PR closing all three + GH #29/#30.
- **D2 — Vocabulary is structs:** `SessionInfo`, `Artifact`, `AgentCore.CommandResult` are
  typed structs like the existing result vocabulary. No bare info maps on public seams.
- **D3 — MIM-67 shape:** optional higher-arity callbacks (`handle_tool_call/4`,
  `handle_event/3`) receiving `%SessionInfo{}`; 3-/2-arity fallbacks keep every published
  handler working unchanged.
- **D4 — One name per verb:** the approved `fetch_output` convenience ships as
  `Artifacts.fetch/3`, not as a second Client function.
- **D5 — Command API surface:** collected-by-default `{:ok, %CommandResult{}}` + optional
  `on_output` streaming callback, reusing the MIM-50 reducer + `idle_timeout` guard.
- **D6 — Cross-provider abstraction, revised:** normalize the **verbs**, not the storage.
  `ReqManagedAgents.Artifacts` behaviour (list/fetch/put/delete; name-keyed,
  session-scoped) with two impls now — `ClaudeFiles`, `AgentCoreSessionStorage` — both
  live-provable on existing infra. `S3Mount` is designed here and **deferred to 0.4**
  (needs VPC harness + S3 Files access point; per-session scoping is path-convention).
- **D7 — Live proof:** all three canary legs (CMA files, AgentCore command, sessionStorage
  mount) ship with the release; the IAM policy gains `InvokeAgentRuntimeCommand` first.

---

## §1 Vocabulary and layering

New structs (all `@derive Jason.Encoder`, typed, documented like the existing vocabulary):

```elixir
%ReqManagedAgents.SessionInfo{session_id: String.t() | nil, provider: module()}
%ReqManagedAgents.Artifact{name: String.t(), size: non_neg_integer() | nil,
                           ref: term(), raw: term()}
# ref is the provider-native identity: CMA file id; sandbox absolute path for
# command-backed stores. raw is the unparsed provider record.
%ReqManagedAgents.AgentCore.CommandResult{stdout: binary(), stderr: binary(),
                                          exit_code: integer() | nil}
```

Layering (strict, one-way):

```
Handler (receives %SessionInfo{})            Session loop — UNCHANGED except info threading
        │ may call
ReqManagedAgents.Artifacts (verbs facade)    list/fetch/put/delete over {impl, store}
        │ composes
Client primitives                            CMA: list_files/delete_file/upload/download/attach
                                             AgentCore: invoke_agent_runtime_command
```

`Session` knows nothing about artifacts; `Artifacts` knows nothing about the loop.

## §2 MIM-67 — SessionInfo threading

- Providers standardize a `session_id` key on the conn map: Claude already sets it;
  `BedrockAgentCore.open/2` adds `session_id: sid` (keeps `sid` internally).
- `Session` builds `info = %SessionInfo{session_id: Map.get(conn, :session_id), provider: provider}`
  after `open/2` succeeds, stores it in state, and **rebuilds it on reconnect** (resume can
  mint a new conn/session).
- `Tools.run/7` gains the info argument. Dispatch, module handlers:
  `function_exported?(handler, :handle_tool_call, 4)` → `/4` with info as 4th arg, else `/3`.
  Fn handlers: `is_function(handler, 4)` → called with `(name, input, ctx, info)`, else the
  existing 3-arity call. Same result contract either way.
- `forward_raw/2` becomes info-aware: `handle_event/3` (`(event, ctx, info)`) when exported,
  else `handle_event/2`.
- `Handler` behaviour: add `@callback handle_tool_call(name, input, ctx, SessionInfo.t())`
  and `@callback handle_event(event, ctx, SessionInfo.t())`, both in `@optional_callbacks`.
  Moduledoc explains the arity dispatch and that the struct grows by fields, never arity.
- `%SessionResult{}` gains `session_id: String.t() | nil` (default nil — additive,
  non-breaking); `session_result/3` fills it from state.

## §3 MIM-66 — CMA files primitives

- `Client.list_files(client, opts \\ [])` → `GET /v1/files`; `opts[:params]` (e.g.
  `%{scope_id: session_id}`) encoded as query string. Returns standard
  `{:ok, %{"data" => files, …}} | {:error, …}`. Session-scoped calls send the combined
  files + managed-agents beta headers (pin exact header set from `download_file/2` at
  plan time; extend `file_headers/2` if needed).
- `Client.delete_file(client, file_id)` → `DELETE /v1/files/{id}`, standard return.
- Both added to `Client.Behaviour`.
- No `fetch_output` on Client (D4) — that verb is `Artifacts.fetch/3` (§5).

## §4 MIM-65 — environment pass-through + command API

**Environment (provision spec fields, not opts — constraint 5):**

- The canonical spec gains two optional fields: `environment` (opaque map → wire
  `"environment"`) and `environment_variables` (opaque map → wire `"environmentVariables"`).
  `BedrockAgentCore.provision/2` copies them into the harness spec;
  `Client.create_harness/2` `maybe_put`s them. RMA never interprets either —
  `model_config` philosophy. Being spec fields, they flow into `harness_name/2`'s hash, so
  differently-mounted specs cannot collide in the Provisioner cache.
- Docs note the AWS gotchas verbatim: `UpdateHarness` replaces the whole
  `filesystemConfigurations` list; EFS/S3 mounts force VPC mode; `sessionStorage` is the
  no-VPC option; mount paths under `/mnt`.

**Command API (data plane):**

- `Client.invoke_agent_runtime_command(client, inv)` with
  `inv :: %{agent_runtime_arn:, runtime_session_id:, command:, idle_timeout: (default 300_000),
  on_output: ((:stdout | :stderr, binary()) -> any()) | nil}`.
  (`agent_runtime_arn` accepts the harness ARN — the wire param is `agentRuntimeArn`; exact
  URI/query/headers pinned from the API reference at plan time.)
- SigV4-signed POST; response streamed through a reducer (same shape as MIM-50's) decoding
  the event stream: `contentDelta` → append to stdout/stderr acc + fire `on_output` per
  chunk in order; `contentStop` → capture `exitCode`. Returns
  `{:ok, %CommandResult{}} | {:error, …}`. `idle_timeout` is the inter-chunk liveness
  guard; no wall clock (long installs stream their own output).
- `CommandResult` is not an error — callers branch on `exit_code`. Transport errors and
  `__stream_error__` frames surface as `{:error, …}` exactly like `invoke_harness/2`.
- Added to no behaviour (AgentCore client has no behaviour seam today; tests inject via
  `req_options`/Bypass as with `invoke_harness`).

## §5 Artifacts — one vocabulary, provider-native stores

**Behaviour** (`ReqManagedAgents.Artifacts`):

```elixir
@callback list(store :: term(), opts :: keyword()) :: {:ok, [Artifact.t()]} | {:error, term()}
@callback fetch(store, name :: String.t(), opts) :: {:ok, binary()} | {:error, term()}
@callback put(store, name :: String.t(), contents :: binary(), opts) :: :ok | {:error, term()}
@callback delete(store, name :: String.t(), opts) :: :ok | {:error, term()}
```

Facade dispatches on a `{impl_module, store}` tuple:
`Artifacts.fetch({ClaudeFiles, store}, "report.md")`. Each impl provides a `store/…`
constructor so stores are built, not hand-assembled.

**`Artifacts.ClaudeFiles`** — `store(client, session_id)`. `list` = `list_files` scoped by
`scope_id`, mapped to `%Artifact{name: filename, ref: file_id, size:, raw:}`. `fetch` =
list → newest match by name → `download_file`. `put` = `upload_file(purpose: "agent")` +
`attach_file_to_session` (`mount_path: opts[:mount_path] || "/data/" <> name`). `delete` =
newest match → `delete_file`.

**`Artifacts.AgentCoreSessionStorage`** — `store(client, agent_runtime_arn,
runtime_session_id, base_path)` (base_path = the `sessionStorage` mountPath, e.g.
`"/mnt/data"`). Command-backed via `invoke_agent_runtime_command`, using **python3
one-liners emitting JSON** (base image guarantee; no `ls`-parsing):
`list` = python walk of base_path (top level) printing `[{name, size}]` JSON;
`fetch` = `base64` of the file (binary-safe), decoded client-side;
`put` = client-side Base64 → python decode-and-write;
`delete` = python `os.remove`. Non-zero exit on any verb →
`{:error, {:command_failed, %CommandResult{}}}` (stderr never swallowed).
**Documented caveat:** report-scale artifacts (the whole payload transits the command
event stream, Base64-inflated ×4/3); not for GB-scale data.

**`Artifacts.S3Mount` (designed, deferred to 0.4):** store = bucket/access-point + prefix
+ mount path; verbs via standard S3 REST (ListObjectsV2/Get/Put/DeleteObject) signed with
the existing `SigV4` module (`service: "s3"`, no new deps). Per-session scoping is a
**path convention** the harness prompt must enforce — named as the impl's documented
weakness. Blocked on: VPC-mode harness + S3 Files access point infra for live validation.
The behaviour above is shaped so this slots in without change.

**Error normalization across impls:** missing name → `{:error, :not_found}`; CMA duplicate
filenames (re-runs accumulate) → `list` returns all, `fetch`/`delete` act on the newest by
`created_at`; provider errors pass through as `{:error, term}`.

## §6 Testing

Offline:
- Files primitives: Bypass/Req.Test per existing client-test conventions (headers asserted,
  incl. combined betas on scoped list); `Client.Behaviour` additions covered by the mock seam.
- Command API: Bypass chunked event-stream tests reusing the frames helper — collected
  result, `on_output` ordering, stderr interleave, non-zero exit, idle-timeout stall
  (mirror of the MIM-50 suite).
- SessionInfo: arity-dispatch tests (module 3/4-arity, fn 3/4-arity, `handle_event/2`/`3`),
  reconnect rebuild, `SessionResult.session_id`.
- Artifacts: each impl against injected fakes (ClaudeFiles via `Client.Behaviour` mock;
  SessionStorage via an injected command fun); facade dispatch; error normalization incl.
  duplicate-name and not-found.
- Environment fields: serialization presence/absence tests + a spec-hash test proving two
  specs differing only in `environment` produce different harness names.

Live (canary; D7 — after the IAM pre-req):
- **CMA files leg:** agent with `agent_toolset_20260401` writes a named file → `Artifacts`
  list/fetch/delete round-trip (also live-proves the combined-beta scoped list).
- **AgentCore command leg:** echo (stdout + exit 0), a stderr + non-zero exit case.
- **sessionStorage mount leg:** provision with
  `environment: %{"agentCoreRuntimeEnvironment" => %{"filesystemConfigurations" =>
  [%{"sessionStorage" => %{"mountPath" => "/mnt/data"}}]}}` → `Artifacts.put` → `fetch`
  round-trip through the command-backed store.
- IAM pre-req (release task, not library code): add `InvokeAgentRuntimeCommand` (both
  naming families, per the CreateHarness/CreateAgentRuntime precedent) to
  `rma-ci-harness-lifecycle`.

## §7 Release mechanics

- Version `0.3.0`; CHANGELOG (Added: Artifacts behaviour + two stores, SessionInfo +
  optional handler callbacks, files primitives, command API, environment spec fields;
  nothing Changed/breaking — all additive).
- README: new "Artifacts" section with the one-vocabulary/three-stores table (S3Mount
  marked 0.4) and the files-vs-mounts parity story; Handler/Client moduledoc updates;
  extend `examples/bedrock_agent_core.exs` teardown section or add a short artifacts
  snippet to the README rather than a fourth example file (keep the example set at three).
- PR: single branch per D1; body carries `Closes #29`, `Closes #30` (GitHub) and
  `Closes MIM-65, MIM-66 and MIM-67` (Linear, plain text, last line).

## Out of scope

- `Artifacts.S3Mount` implementation + its VPC/access-point infra (0.4).
- MIM-68 (outcomes / arbitrary user-event kickoffs) — next release.
- EFS mounts (VPC; no host-side story a library should own).
- Any cross-provider normalization of storage *configuration* — `environment` stays opaque.
- CMA-side command execution (no such API exists).
