# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.9.0 (2026-07-13)

Struct-vocabulary hardening. The provisioning and session surfaces now speak in
typed structs instead of bare maps, and the runtime environment is a first-class,
content-addressed spec. Several public contracts change — see **Migration**.

### Added
- `ReqManagedAgents.Environment.Spec` — a content-addressed environment identity,
  the environment mirror of `Agent.Spec`: typed `runtimes` (`[Provisioner.Runtime.t()]`)
  plus an opaque, provider-verbatim `config`. `new/1` validates runtimes and
  auto-collects any stray top-level keys into `config`; `digest/1` folds the
  environment into the provision content-address (name excluded). Two agents
  provisioned into *different* environments no longer collide on one resource. (#70, #72)
- `ReqManagedAgents.Provisioner.Runtime` — a typed runtime entry (`lang`/`version`/`via`)
  whose `new/1` is the single shape + version-charset validation gate (the charset
  closes shell injection into the rendered bootstrap script). (#72)
- New structs replacing bare-map records: `Agent.Handle` and
  `Provisioner.Environment.Handle` (provisioner handles — `new/1` owns the store's
  JSON round-trip), `Providers.BedrockAgentCore.HarnessSpec` (the CreateHarness DTO),
  and a typed `Session.State` GenServer state. (#68, #69, #71)
- `Provider` conn accessor callbacks — `session_id/1`, `ref/1`, `consumer/1`,
  `resumed?/1` — so `Session` treats a provider's `conn` opaquely. (#72)

### Changed
- **`Provider.provision/2` now takes `Agent.Spec.t()`** and coerces its input via
  `Agent.Spec.new/1` at the boundary; a spec missing `:name`/`:system_prompt` is
  rejected with `{:error, :invalid_agent_spec}` instead of failing later. (#70)
- **Environment configuration moves from the agent spec to a typed `Environment.Spec`**
  passed as `opts[:environment]`; its `config` is handed **verbatim** to the provider's
  wire environment field — CMA `create_environment` config, AgentCore `CreateHarness`
  `environment` — symmetric across providers, with no per-key indexing into `config`.
  (#70, #72)
- **`ensure_environment/3` takes an `Environment.Spec`** (networking and other config
  now under `config`); an invalid runtime surfaces `{:error, :invalid_environment_spec}`. (#72)
- **`ensure_agent/3` / `ensure_environment/3` return `%Agent.Handle{}` / `%Environment.Handle{}`**
  structs (were bare maps; dot-access and JSON output are unchanged). (#69)
- **The `Provider` behaviour gains four required callbacks** (the conn accessors above);
  external `Provider` implementations must add them. (#72)

### Migration
- Pass a **named** `Agent.Spec` (or a map with `:name`) to `provision` — a nameless
  spec is now rejected.
- Put environment config in `opts[:environment]` as an `Environment.Spec` (a flat map
  works too — stray keys auto-collect into `config`).
- `ensure_environment`: pass an `Environment.Spec` (or flat map); top-level `:networking`
  and friends now live under `:config`.
- Custom `Provider` modules: implement `session_id/1`, `ref/1`, `consumer/1`, `resumed?/1`.
- **One-time re-provision:** environment-*bearing* harnesses and environment images
  re-provision once on upgrade (their content-address digest now includes the typed
  environment). Environment-*less* provisions are byte-identical and unaffected.

## v0.8.0 (2026-07-13)

### Added
- `Session.run/2` with a `session_id:` now delivers a new `:prompt` as a user
  message on resume. Previously a resume consolidated prior server-side state to a
  terminal but ignored `opts[:prompt]` — there was no way to reattach *and* deliver
  the next user turn in one call. Now, when a resume lands **idle with no pending
  tool uses** and a `:prompt` is present, it is sent as a `user.message` and driven
  to terminal. Mid-`requires_action` resumes are unchanged: pending tool uses are
  redispatched first and the prompt is never injected into an unfinished turn; a
  resume without a prompt behaves exactly as before. The delivered turn starts a
  fresh request (turn count and accumulator reset), and a fresh (non-resume)
  session never re-delivers its kickoff prompt on a stream-drop reconnect. Additive
  and backward compatible. #66

### Fixed
- `BedrockAgentCore` now rejects a blank or nil `:execution_role_arn` with
  `{:error, {:invalid_opts, :execution_role_arn}}` before calling
  `CreateAgentRuntime`, instead of forwarding it to AWS and surfacing the cryptic
  `HTTP 400 "Value null at 'executionRoleArn'"`. `Keyword.fetch!/2` only guarded a
  missing key, not a present-but-blank value; spec assembly is now routed through a
  validating `build_spec/2`. #64
- `ClaudeManagedAgents` normalizes a provider-qualified model id
  (`"anthropic:claude-sonnet-4-6"`) to the bare id (`"claude-sonnet-4-6"`) the CMA
  endpoint requires, via `normalize_model_id/1` applied where the model id enters
  the request body. Already-bare ids pass through unchanged and the change is scoped
  to the CMA provider only. Fixes the CMA 400 on qualified ids. #65

## v0.7.1 (2026-07-12)

### Fixed
- `Session` no longer drives an empty resume on `ClaudeManagedAgents` when a
  `requires_action` turn's batch resolves to zero `custom_tool_uses`. The batch a
  `session.status_idle` arrives in doesn't always carry the `agent.custom_tool_use`
  events its own `stop_reason.event_ids` reference — they can live in an earlier,
  already-processed batch (observed: a stale/premature idle re-notifying on tool
  calls whose results were already in flight in the same resume). Driving
  `resume_input([], [])` in that case posted `{"events": []}`, which the API
  rejects with a 400 (`"events: value must contain at least 1 item"`).
  `Session` now recovers via a new optional `Provider.pending_tool_uses/1`
  callback — keyed off the session's own accumulated event history, no extra
  round trip — the same recovery `reconnect/3` already does across a stream
  drop; `ClaudeManagedAgents` implements it via the same
  `Consolidate.unanswered_tool_uses/1` helper `reconnect/3` uses. An empty
  resume is now impossible: if nothing is recoverable, the session surfaces a
  loud `{:error, {:unresolved_requires_action, stop_reason}}` instead. Fixes #61.

## v0.7.0 (2026-07-05)

### Added
- `%ReqManagedAgents.Agent.Spec{}` — a content-addressed agent definition; the digest
  covers `system_prompt`, `tools`, `terminal_tool`, and `model_config` (`name` is the
  base, not identity content), the same shape environment specs give environments.
- `ensure_agent/3` — build-if-absent for agents: content-addressed, provision-if-absent
  (a repeat call with the same spec hits the store and returns the same handle instead
  of re-creating), and 409-recover-by-name (a provider-side name collision on
  `<base>_<digest8>` recovers the live agent instead of failing, version-correct even
  with an empty store). Returns the same three-field handle shape as environments:
  `%{agent_id:, name:, digest:}`.
- `tag_agent/4` / `resolve_agent/2` / `prune_agents/3` — movable tag→digest pointers,
  tag resolution (`{:error, :unknown_tag}` on miss, never a silent fallback), and
  explicit GC (archives old versions beyond `keep:`, never touching tagged digests),
  mirroring the environment lifecycle.
- The canonical identity content is unified onto `Agent.Spec.digest/1` (`system_prompt`,
  `tools`, `terminal_tool`, `model_config`): Claude Managed Agents and Bedrock AgentCore
  both derive agent naming from it, so identical content names identically regardless of
  provider. AgentCore harnesses that carry the opaque `:environment`/`:environment_variables`
  passthrough are the one exception — those fields have no place in the provider-agnostic
  `Agent.Spec`, so such harnesses intentionally keep their pre-0.7.0 full-spec digest
  instead of folding onto `Agent.Spec.digest/1`.
- `Session.run/2` (and `start_link/2`) accept `:agent`/`:environment` opts carrying the
  handle returned by `ensure_agent/3`/`ensure_environment/3`; the handle is unpacked to
  `:agent_id`/`:environment_id` before the provider opens the session, so callers stop
  hand-threading raw ids. An explicit `:agent_id`/`:environment_id` still works and
  wins if both are given.

### Security
- Bumped transitive deps `mint` 1.9.0 → 1.9.1 (EEF-CVE-2026-56810 — chunked-response
  memory buffering) and `hpax` 1.0.3 → 1.0.4 (EEF-CVE-2026-58226 — unbounded HPACK
  integer decoding DoS). Patch bumps, no API impact.

**Upgrade note:** specs that conform to the documented `Agent.Spec` type keep
byte-identical agent/harness names across the upgrade — no re-provisioning. The only
exception is hand-built, out-of-contract specs (omitting the `terminal_tool` key
entirely, or passing `environment: nil` explicitly rather than leaving it unset); those
re-provision once on upgrade, which is non-destructive.

## v0.6.2 (2026-07-05)

### Fixed
- `Providers.Local` now resets its per-request turn budget (`polls`, plus the
  duplicate-call and consecutive-error guards) on each new user message, so
  long-lived `start_link` sessions no longer hit the final-turn directive early
  on follow-up turns. Resolves the v0.6.0 limitation note.
- Bedrock AgentCore provisioning waits out a same-name harness in `DELETING` and
  retries the create, instead of failing with `harness_name_conflict` (a transient
  flake when a prior harness is still tearing down). `*_FAILED` and other
  non-reusable statuses still surface the conflict.
- OTel usage mapper (`OpenTelemetry.Attributes`) reads token counts via `Map.get`,
  so a `%ReqManagedAgents.Usage{}` struct can never raise on `Access` (structs
  don't implement it). Hardening — no live path threads a struct here today; the
  string-keyed SSE path is unchanged.

### Changed
- Configuration funnels through a single `ReqManagedAgents.Config` resolver
  (`opts → :req_managed_agents app env → env var → default`); `Client` and AgentCore
  SigV4 credentials route through it. Env-var behavior is unchanged; app-config
  override is now available for AWS credentials. See the README "Configuration" section.
- Internal struct hygiene (no API change): `%ToolUse{}` and `%ToolResult{}` are
  referenced by name across the reconnect / tool-run / resume / corrective paths
  rather than destructured as bare maps.

## v0.6.1 (2026-07-05)

### Changed
- Hygiene: removed internal issue-tracker identifiers and CI account/role
  identifiers from the public surface (a source comment, test annotations,
  and repo docs). No API or behavior change — the library surface is identical
  to v0.6.0; this release simply ships a clean latest.

## v0.6.0 (2026-07-04)

### Added
- **`ReqManagedAgents.Providers.Local`** — the third provider: the agent loop runs
  in-process (`:request_response`, one model call per turn) over a pluggable
  `chat_fun` with a neutral OpenAI-chat-completions-shaped wire contract
  (`chat_fun.(%{model:, messages:, tools:}) :: {:ok, response} | {:error, reason}`).
  Pointing the chat_fun at any OpenAI-compatible endpoint is a bare `Req.post` —
  including a gateway lane with a granted key for hard data-plane budget
  enforcement. Events are synthesized under the `local.*` namespace
  (`local.model_response`, `local.duplicate_tool_call`, `local.directive`);
  `provision/2` is identity. Limitation: `Providers.Local` is primarily scoped to
  `run/2` (one request per conn) — the final-turn directive counts polls across the
  conn's lifetime, so long-lived `start_link` sessions with many follow-ups may see
  it fire early on later requests.
- Local loop guards (relocated from an internal agent runner, for
  weak-instruction-following local models): duplicate-call dedup (self-answered,
  never re-surfaced), consecutive-error corrective directives (≥2 per tool),
  final-turn directive (names the spec's `terminal_tool`), and transient-error
  retry with exponential backoff around the chat call (HTTP 408/≥500 + transport
  errors; `max_chat_retries`/`retry_backoff_ms`/`sleep_fun` opts).
- Optional `req_llm` dependency (`~> 1.10`, raise-at-first-use via
  `Local.Deps`) backing the default chat_fun; `model_config[:api_key]` and
  `[:base_url]` thread into the ReqLLM call.
- api_key carry-in: the Claude Managed Agents provider builds its client from
  `model_config: %{api_key:, base_url:}` when no `:client` is injected.
  (Bedrock AgentCore signs with SigV4 — not applicable.)
- Metadata carry-in: `model_config[:metadata]` merges into every telemetry
  event's metadata and into `SessionInfo.metadata` for `handle_event/3` —
  decision correlation (`mimir_request_id`, `decision_id`) rides uniformly
  across providers.

### Changed
- Positioning: "one Session loop, any loop host — server-side (Claude Managed
  Agents, AgentCore) or in-process (Local)". README, package description, and
  moduledocs updated; vocabulary and result shapes unchanged.

## v0.5.0 (2026-07-04)

### Added
- **`turn_guard`** — the between-turn governance hook, invoked after each turn's usage
  accumulation with `%{usage: %ReqManagedAgents.Usage{}, turns:, session_id:}`, returning
  `:cont` or `{:halt, reason}`. On halt the run stops with
  `{:error, {:halted, reason}}` and a `:terminated` `SessionResult` is notified. This
  contract is frozen: hosts compose policy (budget caps, grant checks) on top; RMA ships
  only the mechanism. Semantics: the guard runs *before* the `max_turns` check and wins
  when both would trip on the same turn; it fires on terminal-tool re-prompt turns (whose
  `turns` counter keeps incrementing); guards must not raise.
- Terminal-tool enforcement: `require_terminal_tool: true` + `terminal_tool: "name"` +
  `max_reprompts` (default 2). An `:end_turn` that never called the terminal tool is
  re-driven with a re-prompt; exhausted re-prompts finish with
  `stop_reason: :no_terminal_tool`. Re-prompt turns count against `:max_turns`.
- `rma.text_delta` — one documented synthetic event
  (`%{"type" => "rma.text_delta", "text" => chunk}`) emitted through `handle_event`
  alongside (never instead of) the raw event, on every provider that implements the new
  optional `Provider.text_delta/1`. Never stored in `SessionResult.events`.
- Outcomes (GH #31): `Event.define_outcome/3`, the `:outcome` Session option — a
  `%ReqManagedAgents.Outcome{}` struct or a map with the same atom keys — honored by
  the Claude Managed Agents kickoff (`user.define_outcome`; mutually exclusive with
  `:prompt`, outcome wins), optional `Provider.supports_outcomes?/0`
  (`{:error, :outcome_unsupported}` on Bedrock AgentCore), and terminal mapping for
  outcome stop reasons (`satisfied`/`max_iterations_reached` → `:end_turn`, `failed` →
  `:terminated`; `span.outcome_evaluation_end` with `needs_revision` is not terminal).
  Shape validation via `ReqManagedAgents.Outcome.new/1` (one gate shared by the start-time
  check and the kickoff): a non-nil `:outcome` that is not a valid struct or atom-keyed
  `%{description: binary, rubric: binary}` fails fast at start with
  `{:error, {:invalid_opts, :outcome}}` before provider-support is checked.
- `Session.send_event/2` — post a pre-built raw user event (e.g.
  `user.tool_confirmation`) into a running streaming session.

### Changed
- `TurnResult`/`SessionResult` `stop_reason` typespec widened to
  `String.t() | map() | atom() | nil` (`:no_terminal_tool`).

## v0.4.2 (2026-07-04)

### Changed
- Internal housekeeping: source comments and test names no longer reference
  internal tracker ids. No behavior, API, or documentation changes.

## v0.4.1 (2026-07-04)

### Fixed
- `Session.run/2` timeout now shuts down the in-flight poll task (Bedrock AgentCore
  invoke) and the streaming SSE consumer, so the client HTTP stream is torn down
  instead of continuing after the caller received `{:error, :timeout}`. Server-side
  execution may still run to the provider's own limit — on AgentCore, `timeoutSeconds`
  remains the authoritative server budget (Session moduledoc updated to match).

## v0.4.0 (2026-07-04)

### Added
- `ReqManagedAgents.Provisioner.Store` behaviour (`get/2`, `put/3`, `delete/2`,
  `delete_value/2`) — pluggable provision and tag storage. Two implementations: `Store.ETS`
  (default; in-process, unchanged semantics) and `Store.File` (JSON, `path:` required,
  atomic writes, single-writer assumption; handles and tags survive OS-process restarts for
  CLI/mix-task/cron consumers). `:store` option threads through `Provisioner.ensure/3`,
  `evict/2`, `ensure_environment/3`, `tag/4`, `resolve/2`, `prune_environments/3`, and
  the facade `provision/3` / `teardown/3`.
- `ReqManagedAgents.ensure_environment/3` (facade; delegates to `Provisioner.Environments`)
  — content-addressed, build-if-absent environment lifecycle. Provider-side name is
  `<base>_<digest8>`; a 409 recovers by name (same name = same image, always). Returned
  handle: `%{environment_id:, name:, digest:}`. Error taxonomy:
  `{:environment_archived, name}` (name exists but archived) /
  `{:environment_name_conflict, name}` (absent after 409 — unexpected provider state).
- `Provisioner.tag/4` — writes a movable `base:tag → digest` pointer to the configured
  store. `Provisioner.resolve/2` — resolves `"base:tag"` to a handle; never falls back;
  `{:error, :unknown_tag}` on miss; raises `ArgumentError` on a malformed ref (no colon).
- `Provisioner.prune_environments/3` — explicit image GC for a named base: archives
  versions beyond the newest `keep:` (REQUIRED, no default — deliberate friction for a
  permanent operation), always protecting tagged digests. Strict 8-hex suffix membership
  (a `"data"` prune never touches `"data_analysis"` images). Returns
  `{:ok, %{archived: [...], kept: [...]}}` or
  `{:error, {:partial, archived_so_far, {failed_name, reason}}}` on partial failure.
- Base-scoped digest index (`"digest:<base>:<digest8>"` store entries written at ensure
  time) so `resolve/2` can look up handles without a linear scan; the base scope prevents
  two bases sharing an identical spec from resolving each other's environments.
- `Provisioner.Runtimes`: `runtimes: [%{lang:, version:, via: :mise}]` on env specs
  participates in the spec digest automatically (a runtime change = a new image). When
  runtimes are declared, `ensure_environment/3` returns `bootstrap: %{script:, instructions:}`
  in the handle (derived on every call, never stored). `bootstrap_script/1` renders the
  mise install script; `system_prompt_block/1` renders the agent instruction. `required_hosts/1`
  feeds the allowlist merge into `networking.allowed_hosts` when networking is `:limited`.
  Spike-proven: ~11s end-to-end on ubuntu-24.04 (precompiled OTP via mise, no kerl compile).
  Only `via: :mise` is supported.

### Changed
- Provisioner cache keys namespaced: handles now stored under `"provision:" <> hash`
  (previously bare hash). Cache-only — existing entries are invisible to the new reader
  (re-provisions once per BEAM start on first upgrade); no consumer API impact.
- Facade `teardown/3` forwards `:store` to `Provisioner.evict/2` so teardown clears the
  persistent store when a `Store.File` is in use.

## v0.3.0 (2026-07-03)

### Known limitations
- ~~Claude Managed Agents: sandbox-written files not retrievable~~ **RESOLVED same day
  (post-release probe): it's the outputs-dir convention.** Only files the agent writes
  under `/mnt/session/outputs/` become session artifacts (session-scoped, downloadable);
  files written elsewhere are non-downloadable residue. `Artifacts.ClaudeFiles` works
  as shipped — direct your agent's deliverables to `/mnt/session/outputs/` in its
  system prompt.

### Added
- `ReqManagedAgents.Artifacts` — one vocabulary (`list`/`fetch`/`put`/`delete`,
  name-keyed, session-scoped) over provider-native session storage, with two stores:
  `Artifacts.ClaudeFiles` (Anthropic Files API) and `Artifacts.AgentCoreSessionStorage`
  (AgentCore `sessionStorage` mount, command-backed, report-scale). `%Artifact{}` struct.
- `%SessionInfo{}` handed to handlers via optional `Handler.handle_tool_call/4` and
  `handle_event/3` (existing 3-/2-arity handlers work unchanged);
  `SessionResult.session_id`.
- CMA Files API completion: `Client.list_files/2` (session-scoped via `scope_id`) and
  `Client.delete_file/2`, on `Client.Behaviour` too.
- AgentCore: opaque `environment`/`environment_variables` provision-spec fields
  (filesystem mounts, custom containers, env vars — pass-through, spec-hash covered) and
  `Client.invoke_agent_runtime_command/2` (direct microVM shell; streamed
  stdout/stderr via optional `on_output`; `%AgentCore.CommandResult{}`).

## v0.2.1 (2026-07-03)

### Changed
- Internal code hygiene only — the codebase now passes `mix credo --strict`
  (alias ordering/aliasing, implicit `try`), and CI gates on `--strict` so it
  stays that way. No user-facing changes.

## v0.2.0 (2026-07-03)

### Changed
- Bedrock AgentCore `InvokeHarness` now streams incrementally: turns are guarded by an
  inter-chunk `idle_timeout` (default 300s) instead of a 10-minute whole-body wall clock,
  so long-running turns complete while dead connections fail fast.
- `Handler.handle_event/2` fires live during AgentCore turns (previously only after the
  turn completed) and is documented as at-least-once across retried attempts.
- `Client.new`'s `receive_timeout` now governs control-plane calls only; the invoke data
  plane is guarded by the per-invoke `idle_timeout` instead (callers who used
  `receive_timeout` to cap invokes should now pass `idle_timeout`/`timeout_seconds`).

### Added
- Per-invocation AgentCore server budgets on `Session.run/2` opts: `timeout_seconds`,
  `max_iterations`, `max_tokens` (wire: `timeoutSeconds`/`maxIterations`/`maxTokens`).
- `idle_timeout` opt on the AgentCore invoke path.
- `[:req_managed_agents, :stream, :event]` telemetry now also fires for AgentCore turns.

## v0.1.0 (2026-07-03)

First public release. Provider-agnostic client for **managed agent runtimes**:
the provider runs the agent loop; your custom tools execute locally on your
node. The provider only ever sees each tool's name, description, input schema,
and the text result you return.

### Providers

- `ReqManagedAgents.Providers.ClaudeManagedAgents` — Anthropic Claude Managed
  Agents (public beta, `managed-agents-2026-04-01`). `:streaming` transport
  over long-lived SSE.
- `ReqManagedAgents.Providers.BedrockAgentCore` — AWS Bedrock AgentCore
  Harness (GA) via ConverseStream. `:request_response` transport over
  `application/vnd.amazon.eventstream` (decoded by
  [`aws_event_stream`](https://hex.pm/packages/aws_event_stream)).
  The AWS dependencies (`ex_aws_auth`, `aws_event_stream`) are **optional** —
  Anthropic-only consumers don't pull them; AgentCore raises an actionable
  error at first use if they're missing.

### Core

- `ReqManagedAgents.Provider` behaviour — one canonical turn vocabulary
  across backends: `custom_tool_use` / `custom_tool_result` (client-executed,
  return-of-control tools only), a three-atom terminal
  (`:end_turn | :requires_action | :terminated`), and `%TurnResult{}` /
  `%SessionResult{}` with per-turn token usage.
- Two drivers over the same vocabulary: `ReqManagedAgents.run_to_completion/1` (synchronous) and `ReqManagedAgents.Session` (supervised GenServer;
  reconnect with event consolidation/deduplication, concurrent tool
  execution, full-history paging).
- `ReqManagedAgents.Handler` behaviour for local tool execution;
  `ReqManagedAgents.Provisioner` for idempotent provider-side agent/harness
  provisioning and teardown.
- Anthropic control plane: agents, environments, sessions, events, Files API
  (upload / attach / download).
- Telemetry event tree (`[:req_managed_agents, …]` — request, stream, tool,
  session) with caller metadata injection, plus an optional OpenTelemetry
  bridge emitting `gen_ai.*` spans.

### Hardening (validated against live provider APIs)

- AgentCore ConverseStream tool blocks keyed by `toolUseId` (robust to
  index-reuse in live streams); resume turns carry both the assistant
  `toolUse` and user `toolResult` messages, as the harness requires.
- Exception/error stream frames surface as distinct errors rather than
  silent terminals; bounded per-turn invoke retry on transport errors and
  truncated streams.
- SigV4 signing is session-token aware (works with STS/OIDC temporary
  credentials).
- Client structs redact secrets from `inspect/1` output (`api_key`, AWS
  `credentials`) — a `KeyError` from missing session opts or a crash report
  can't leak them into logs.
