# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
