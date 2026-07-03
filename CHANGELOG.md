# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.3.0 (2026-07-03)

### Known limitations
- **Claude Managed Agents (beta): sandbox-written files are not yet retrievable by the
  host.** The session-scoped Files listing (`scope_id`) does not associate files the agent
  writes in its sandbox, and such file objects are not downloadable (verified live,
  2026-07-03). `Artifacts.ClaudeFiles` is wire-complete per the platform docs and works
  the moment the provider enables the flow; until then,
  `Artifacts.AgentCoreSessionStorage` (Bedrock) is the working artifacts store, and
  `ClaudeFiles.put` (upload + attach inputs) works today.

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
