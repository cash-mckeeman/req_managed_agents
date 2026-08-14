# ReqManagedAgents

One Session loop, any loop host — server-side (Claude Managed Agents, AgentCore) or in-process (Local). **Your custom tools execute on your node** regardless of which host runs the loop, so your code and data never leave it — the loop host only ever sees each tool's name, description, input schema, and the text result you return.

One loop, three backends behind a single `Provider` behaviour:

| Provider | Module | Transport |
|---|---|---|
| **Anthropic Claude Managed Agents** (public beta) | `ReqManagedAgents.Providers.ClaudeManagedAgents` | `:streaming` — long-lived SSE; beta header `managed-agents-2026-04-01` |
| **AWS Bedrock AgentCore Harness** | `ReqManagedAgents.Providers.BedrockAgentCore` | `:request_response` — synchronous SigV4-signed invoke |
| **Local (in-process)** | `ReqManagedAgents.Providers.Local` | `:request_response` — in-process loop over a pluggable `chat_fun` (default: ReqLLM via the optional `req_llm` dep); one model call per turn; loop guards for weak-instruction-following local models; reattachable via `history:` |

### Local + routing

Point Local's `chat_fun` at an OpenAI-compatible gateway lane (`base_url` + per-run `api_key`
via `model_config`) and you get hard data-plane budget enforcement with no coupling to the
gateway's internals. Direct-to-provider `chat_fun`s remain available for dev and tests.

```elixir
{:ok, result} =
  ReqManagedAgents.Session.run(ReqManagedAgents.Providers.Local,
    handler: MyTools,
    spec: %{system_prompt: "...", tools: tools, terminal_tool: "submit", model_config: nil},
    model_config: %{model: "openai:gpt-oss", base_url: lane_url, api_key: granted_key},
    prompt: "Go."
  )
```

(`Providers.Local` reads the bare-map `spec` keys directly and never coerces to
`%Agent.Spec{}`, so it takes no `:name`; the managed providers do — see "Provision
once, run anywhere".)

## Install

```elixir
def deps do
  [{:req_managed_agents, "~> 0.1"}]
end
```

Using the Bedrock AgentCore provider? Add the optional AWS deps (Anthropic-only
users can skip these):

```elixir
def deps do
  [
    {:req_managed_agents, "~> 0.1"},
    {:ex_aws_auth, "~> 1.4"},
    {:aws_event_stream, "~> 0.1"}
  ]
end
```

Using `Providers.Local` with the **default chat_fun** (ReqLLM)? Add:

```elixir
def deps do
  [
    {:req_managed_agents, "~> 0.1"},
    {:req_llm, "~> 1.10"}
  ]
end
```

Injected `chat_fun`s (any OpenAI-compatible endpoint via plain `Req`) need nothing extra.

## Configuration

Every config/credential value the library reads funnels through
`ReqManagedAgents.Config`, in one fixed priority order: an explicit `opts`
keyword wins, then `Application.get_env(:req_managed_agents, key)`, then a
`System.get_env` environment variable, then a default. This is the complete
list of keys read anywhere in the library:

| Key | opt | `:req_managed_agents` app env | ENV var | Default |
| --- | --- | --- | --- | --- |
| Anthropic API key | `:api_key` | `:api_key` | `ANTHROPIC_API_KEY` | *(required)* |
| Base URL | `:base_url` | `:base_url` | — | `"https://api.anthropic.com"` |
| Beta header | `:beta` | `:beta` | — | `"managed-agents-2026-04-01"` |
| Files beta header | `:files_beta` | `:files_beta` | — | `"files-api-2025-04-14"` |
| Anthropic API version | `:anthropic_version` | `:anthropic_version` | — | `"2023-06-01"` |
| Receive timeout (ms) | `:receive_timeout` | `:receive_timeout` | — | `60_000` |
| Provider profile | `:profile` | `:profile` | — | `:anthropic` |
| AWS access key ID | `:aws_access_key_id` | `:aws_access_key_id` | `AWS_ACCESS_KEY_ID` | *(required)* |
| AWS secret access key | `:aws_secret_access_key` | `:aws_secret_access_key` | `AWS_SECRET_ACCESS_KEY` | *(required)* |
| AWS region | `:aws_region` | `:aws_region` | `AWS_REGION`, then `AWS_DEFAULT_REGION` | `"us-east-1"` |
| AWS session token | `:aws_session_token` | `:aws_session_token` | `AWS_SESSION_TOKEN` | `nil` |

`Client.new/1` resolves the Anthropic keys; `AgentCore.SigV4.from_env/1`
resolves the AWS keys (it still works called with no args — `opts` just gives
you an override point without touching the environment).

## The core: one loop, the loop host is a parameter

`ReqManagedAgents.Session` is the unified loop — invoke a turn → run your return-of-control tools
locally → resume → repeat — parameterized by a provider module. The loop host runs the agent loop —
a managed provider server-side, or `Providers.Local` in-process. It returns the **same** result
shape for every provider:

```elixir
alias ReqManagedAgents.Session
alias ReqManagedAgents.Providers.{ClaudeManagedAgents, BedrockAgentCore}

# `handle` is what `provision/3` returns — see "Provision once, run anywhere" below.

# Claude Managed Agents (streaming) — `agent:`/`environment:` take the handle
# (each lifts the id it needs); no hand-threaded raw ids.
{:ok, %ReqManagedAgents.SessionResult{} = result} =
  Session.run(ClaudeManagedAgents,
    client: ReqManagedAgents.new(), agent: handle, environment: handle,
    prompt: "…", handler: MyHandler)

result.terminal   # :end_turn | :requires_action | :terminated — uniform across providers
result.text       # the assistant's accumulated text
result.usage      # %ReqManagedAgents.Usage{input_tokens:, output_tokens:, …}
result.transcript # client-held history (Local) for reattach, else nil (server-held providers)

# AWS Bedrock AgentCore (request/response) — same handler, same result struct;
# its handle carries a `harness_arn`.
{:ok, %ReqManagedAgents.SessionResult{}} =
  Session.run(BedrockAgentCore,
    harness_arn: handle.harness_arn, runtime_session_id: sid,
    prompt: "…", handler: MyHandler)
```

`terminal` is the **uniform** signal to branch on. `stop_reason` is each provider's **raw native value** (a map for Claude, e.g.
`%{"type" => "end_turn"}`; a string for Bedrock, e.g. `"end_turn"`) — preserved verbatim, never
flattened. The raw events are always in `events`.

- **Sync:** `Session.run(provider, opts)` blocks until a terminal and returns `{:ok, …}` /
  `{:error, reason}`.
- **Live / supervised:** `Session.start_link(provider, opts)` (reconnecting, multi-turn) +
  `Session.message(pid, text)`; pass `notify: pid` to be told when a turn terminates.

### Convenience facade (Claude)

For the Claude path, thin sugar over the above:

- `ReqManagedAgents.run_to_completion/1` ≡ `Session.run(ClaudeManagedAgents, opts)`
- `ReqManagedAgents.start_session/1` ≡ `Session.start_link(ClaudeManagedAgents, opts)`
- `ReqManagedAgents.new/1` — a control-plane client.

For the Bedrock path, `ReqManagedAgents.AgentCore.invoke_to_completion/1` ≡
`Session.run(BedrockAgentCore, opts)`.

## Writing a handler

Implement `ReqManagedAgents.Handler` — `handle_tool_call/3` runs your tool locally and returns the
text result; the optional `handle_event/2` observes raw events as they stream.

```elixir
defmodule MyHandler do
  @behaviour ReqManagedAgents.Handler

  @impl true
  def handle_tool_call("lookup_customer", %{"email" => email}, _ctx),
    do: {:ok, "Customer #{email}: Pro plan, active."}   # your private code + data

  @impl true
  def handle_event(_ev, _ctx), do: :ok
end
```

Three runnable, heavily-commented examples ship with the package:

- [`examples/claude_managed_agents.exs`](examples/claude_managed_agents.exs) — the full Claude
  lifecycle: `provision/3` (agent + environment in one call), a local tool handler, and the
  `%SessionResult{}` (text, terminal, token usage).
- [`examples/bedrock_agent_core.exs`](examples/bedrock_agent_core.exs) — AgentCore Harness:
  the same `provision/3` → `Session.run/2` → `teardown/2` shape, plus the AWS
  gotchas (session-id contract, cross-region model profiles, async deletion).
- [`examples/provider_agnostic.exs`](examples/provider_agnostic.exs) — the core claim: one
  handler, one loop, two providers, same result shape.

## Provision once, run anywhere

Both managed providers speak **one vocabulary**: build an `%ReqManagedAgents.Agent.Spec{}`
(a `:name` is required — `Agent.Spec.new/1` rejects a nameless spec), provision it — passing
any environment as the `:environment` option (an `Environment.Spec`, or a flat map that coerces
to one; its `config` is handed **verbatim** to the provider's wire environment field, no per-key
indexing) — and thread the returned handle into `Session.run/2`. The provider module is the only
thing you change.

```elixir
alias ReqManagedAgents.Agent.Spec

spec = %Spec{
  name: "billing-support",
  system_prompt: "You are a concise billing-support agent. Use tools for customer data.",
  model_config: model_config,   # provider-specific wire shape — see the table
  tools: tools                  # SCHEMAS only; the implementations stay in your Handler
}

# create-or-reuse, cached in-process per {provider, spec}; `teardown/2` releases it
{:ok, handle} = ReqManagedAgents.provision(provider, spec, environment: env_spec)

# then thread `handle` into Session.run — the connection opts are the one
# per-provider difference (see the table below).
```

What actually differs between the two providers is only this:

| | Claude Managed Agents | Bedrock AgentCore |
|---|---|---|
| **mode** | `:streaming` — long-lived SSE, events pushed | `:request_response` — one synchronous signed invoke per turn |
| **credentials** | `ANTHROPIC_API_KEY` + beta header | AWS SigV4 (`AWS_*`) + an execution-role ARN |
| **`model_config` wire** | plain model-id string (`"claude-haiku-4-5"`) | `%{"bedrockModelConfig" => %{"modelId" => "us.…"}}` (cross-region inference profile) |
| **provision creates** | a versioned agent **and** an environment (two resources) | one harness folding in model + tools + environment |
| **provision handle** | `%{agent_id:, environment_id:}` | `%{harness_arn:, harness_id:}` |
| **`Session.run` connection** | `agent: handle, environment: handle` | `harness_arn: handle.harness_arn, runtime_session_id: sid` (id ≥33 chars) |
| **capabilities** | outcomes, server-tool observation, cross-batch tool recovery, resume/reconnect (stream-level, with `reconnect/3` event recovery) | `session_id:` reattach within the session window (no event recovery — a dropped turn just re-invokes) |

`:agent`/`:environment` accept a handle (a struct, or a bare map with the same
`agent_id:`/`environment_id:` keys) and unpack to the raw ids before the provider opens the
session; an explicit `:agent_id`/`:environment_id` still works and wins if both are given.

Each AgentCore turn is one signed invoke; resume re-sends the assistant `toolUse` + your
`toolResult` delta. Long runs stream incrementally with **no client wall clock** — only silence
fails a turn (`idle_timeout:`, inter-chunk guard, default 300s); cost is bounded server-side via
`timeout_seconds:`/`max_iterations:`/`max_tokens:` (per-invocation overrides of the harness
defaults). `Session.run/2`'s own `:timeout` must be ≥ the server budget — a client timeout returns
`{:error, :timeout}` but does NOT cancel the in-flight invoke; the harness keeps executing (and
billing) up to its `timeoutSeconds`. Events reach `Handler.handle_event/2` live either way.

**Reattach (0.10):** pass `session_id:` (the id from a prior `SessionResult.session_id`) instead
of `runtime_session_id:` to resume an existing AgentCore runtime session within its session
window — `resumed?/1` reflects the reattach honestly. There's no event-list surface to replay on
this path, so a custom `Provider.reconnect/3` isn't required for it: `Session` defaults an
unimplemented `reconnect/3` to `{:ok, conn, [], seen}` and proceeds. Beyond-window re-seed is a
planned follow-up. `Providers.Local` has its own reattach seam: pass `history:` (a prior
`SessionResult.transcript`) to `open/2` to seed a conversation verbatim; `resumed?/1` reflects it
and `transcript/1` exposes the grown history. Any provider whose history lives client-side can
implement the optional `transcript/1` callback — `Session` embeds it into `SessionResult.transcript`
at terminal (`nil` for server-held providers like Claude Managed Agents and AgentCore).

### Provisioning budget (Bedrock AgentCore)

`provision/3` takes `:timeout` (ms, default 365 000) as the budget for the whole call. It
becomes a monotonic deadline at entry, shared by the wait for a same-name harness to finish
deleting, the wait for the new one to reach READY, and the wait for the endpoint an invoke
will reach — and it bounds every request those waits make, so a provision that cannot finish
returns a named `{:error, {tag, %WaitContext{}}}` inside the budget rather than overrunning
the deadline it is running under. (The best-effort
`DeleteHarness` that rolls back a harness this call created is the deliberate exception: it
runs after the budget is spent and carries a small fixed budget of its own.)

**The budgets are additive, so size them that way.** `provision` and `Session.run/2` run in
sequence, and the defaults do **not** compose: 365 s of provisioning plus `run/2`'s 600 s
default exceeds a 900 s enclosing limit. The constraint is

```
provision :timeout  +  Session.run/2 :timeout  +  margin  ≤  your enclosing deadline
```

where the enclosing deadline is whatever kills you from outside — a CI job timeout, an ExUnit
`@tag timeout:`, a supervisor. Getting this wrong is the failure this budget exists to make
diagnosable: the enclosing timeout fires first, the process is killed mid-wait, and no named
error is ever returned.

**A harness reaching READY is not the end of provisioning.** The harness and each of its
endpoints carry separate statuses: measured live, a harness was READY in 11 s while its
`DEFAULT` endpoint took 2 m 31 s, and an invoke against a still-creating endpoint fails. So
`provision/3` waits for the endpoint too, polling it only once the harness is READY (the common
path costs one extra call, not one per poll). The endpoint is `:endpoint_name`, defaulting to
`DEFAULT` — the endpoint `InvokeHarness` uses when no `qualifier` is given. Its failures carry
their own tags (`:endpoint_ready_timeout`, `:endpoint_failed`, `:endpoint_terminating`,
`:endpoint_unknown_status`) so an endpoint problem never reads as a harness one. Size `:timeout`
for both waits.

The `:timeout` also derives the poll cadence when `:ready_poll_ms` is not given, so a short
budget still polls repeatedly rather than looking once. Note that the bound covers each
request's *receive* phase; a retried call also spends Req's backoff sleeps and Finch's connect
timeout outside it, so leave margin rather than sizing to the millisecond.

## Layers

- `ReqManagedAgents.Provider` — the behaviour every backend implements (invocation + `normalize/1`).
- `ReqManagedAgents.Session` — the unified, supervised, reconnecting loop driven by your `Handler`.
- `ReqManagedAgents.Client` — Claude control-plane HTTP (agents, sessions, events, files).
- `ReqManagedAgents.SSE` / `.Stream` — the Claude event stream.
- `ReqManagedAgents.AgentCore.Client` / `.Converse` / `ReqManagedAgents.Provisioner` — Bedrock
  AgentCore wire client, Converse decoding, and Harness provisioning.
- `ReqManagedAgents.Event` / `.Consolidate` — pure builders, classification, reconnect helpers.
- `ReqManagedAgents.ToolSchema` — custom-tool schema construction.
- `ReqManagedAgents.Artifacts` / `.Artifact` / `.SessionInfo` — name-keyed session-artifact verbs over provider-native stores + the runtime identity handed to handlers.
- `ReqManagedAgents.SessionResult` / `.TurnResult` / `.Usage` / `.ToolUse` / `.ToolResult` — the
  canonical result vocabulary shared by every provider.

## Telemetry

`req_managed_agents` emits `:telemetry` events you can attach to:

| Event | Measurements | Metadata |
|---|---|---|
| `[:req_managed_agents, :request, :start \| :stop \| :exception]` | `duration` | `method`, `path`, `status` |
| `[:req_managed_agents, :agent_core, :request, :start \| :stop \| :exception]` | `duration` | `operation`, `service`, `method`, `path`, `status` |
| `[:req_managed_agents, :agent_core, :provision, :poll]` | `elapsed_ms`, `poll_n` | `harness_id`, `status`, `phase` |
| `[:req_managed_agents, :agent_core, :provision, :stop]` | `duration_ms`, `polls` | `harness_id`, `phase`, `result` |
| `[:req_managed_agents, :agent_core, :provision, :exception]` | `duration_ms` | `harness_id`, `phase`, `kind`, `result` |
| `[:req_managed_agents, :stream, :connected \| :event \| :done \| :error]` | — | `session_id`, `type`, `usage`, `reason` |
| `[:req_managed_agents, :tool, :start \| :stop \| :exception]` | `duration` | `tool`, `session_id`, `is_error` |
| `[:req_managed_agents, :session, :tool_uses]` | `tool_use_count` | `turn`, `tool_use_ids` |
| `[:req_managed_agents, :session, :terminal]` | — | `terminal` |

The `:provision` events fire once per poll and once per terminal outcome while a Bedrock
AgentCore harness is being provisioned; `phase` is `:ready`, `:endpoint` or `:deleted`, and `result` is
`:ok` or `{:error, tag}`. The same fields are also written to the log, so a provisioning
failure is diagnosable without attaching a handler.

All providers run through `Session`, so the `:session` events fire regardless of loop host.
`:stream` `:event` also fires for **both** providers as events arrive mid-turn — on Claude,
`type` is the SSE event type and `session_id`/`usage` are set; on Bedrock AgentCore, `type` is
the Converse envelope key (e.g. `"contentBlockDelta"`) and there is no `session_id`. The other
`:stream` events (`:connected`/`:done`/`:error`) are Claude-only. Pass
`telemetry_metadata: %{…}` to merge custom tags (e.g. tenant) into every event; library-set keys
take precedence. `ReqManagedAgents.OpenTelemetry` bridges these to OTel GenAI spans.

## Files (Claude)

```elixir
{:ok, %{"id" => file_id}} = ReqManagedAgents.Client.upload_file(client, %{purpose: "agent", file: "report.csv"})
{:ok, _} = ReqManagedAgents.Client.attach_file_to_session(client, session_id, %{file_id: file_id, mount_path: "/data/report.csv"})
{:ok, bytes} = ReqManagedAgents.Client.download_file(client, file_id)
```

The Files API uses its own beta header (`files-api-2025-04-14`); `download_file/2` returns raw bytes.

## Artifacts — retrieve what your agent built

An agent writes deliverables into its session sandbox; the file's **name** is the only
identity the model ever sees. `ReqManagedAgents.Artifacts` gives one vocabulary over
provider-native session storage — `list`, `fetch`, `put`, `delete`, name-keyed and
session-scoped:

```elixir
alias ReqManagedAgents.Artifacts
alias ReqManagedAgents.Artifacts.{ClaudeFiles, AgentCoreSessionStorage}

# Claude Managed Agents — the Files API, scoped to one session
store = {ClaudeFiles, ClaudeFiles.store(client, session_id)}
{:ok, artifacts} = Artifacts.list(store)             # [%ReqManagedAgents.Artifact{name: "report.md", …}]
{:ok, bytes}     = Artifacts.fetch(store, "report.md")

# Bedrock AgentCore — a sessionStorage mount (no VPC), command-backed
store =
  {AgentCoreSessionStorage,
   AgentCoreSessionStorage.store(ac_client, harness_arn, runtime_session_id, "/mnt/data")}
{:ok, bytes} = Artifacts.fetch(store, "report.md")
```

Handlers receive a `%ReqManagedAgents.SessionInfo{}` (optional 4th argument to
`handle_tool_call/4`) carrying the `session_id`, so a tool can build the store for its
OWN session and fetch what the agent just wrote.

The parity story, honestly: Anthropic offers a provider-hosted blob store (zero infra;
bytes on Anthropic); AWS mounts **your** storage into the microVM (`sessionStorage`
needs nothing; EFS/S3 mounts need VPC mode) plus direct shell access
(`AgentCore.Client.invoke_agent_runtime_command/2` — no model loop, no token cost).
The `sessionStorage` store handles report-scale artifacts (bytes transit the command
stream as Base64); an S3-mount store (host side = plain S3) is designed for 0.4.
Declare mounts via the `:environment` provisioning option (an `Environment.Spec`; its
`config` is passed verbatim to the provider's wire environment field).

> **The outputs-dir convention (Claude Managed Agents, established live 2026-07-03):**
> only files the agent writes under **`/mnt/session/outputs/`** become session
> artifacts — scoped to the session, downloadable, retrievable via `ClaudeFiles`.
> Files written elsewhere (e.g. `/workspace`) leave non-downloadable, unscoped
> residue. The path is exposed as `ClaudeFiles.outputs_dir/0` (+
> `output_path/1` for a named file) — interpolate it into your agent's system
> prompt instead of copying the string.

## Environments are images

The Docker mental model maps directly onto the CMA environment lifecycle — with
the same rules: a changed spec is a *new image*, not an in-place update; tags are
movable pointers; sessions are the containers that churn; prune is explicit GC.

| Docker | RMA |
|---|---|
| Dockerfile | env spec (canonical map) |
| image digest | spec hash — content-addressed identity |
| repository | base name (`"data_analysis"`) |
| `repo@digest` | provider-side name `<base>_<digest8>` |
| `docker build` (cached) | `ensure_environment/3` — build-if-absent, never rebuilds on a hit |
| `repo:tag` (movable) | Store-backed tag → digest pointer |
| `docker run` | `create_session` — ephemeral, references an image |
| `docker image prune` | `prune_environments/3` — explicit GC, never automatic |

### Worked example

```elixir
alias ReqManagedAgents.Provisioner
alias ReqManagedAgents.Provisioner.Store

store = {Store.File, path: Path.expand("~/.cache/myapp/provisions.json")}
env_spec = %{type: "cloud", packages: %{pip: ["pandas"]}, networking: %{type: "unrestricted"}}

# Build once — next run hits the store and returns the same handle instantly:
{:ok, handle} =
  ReqManagedAgents.ensure_environment(client, env_spec, name: "data_analysis", store: store)
# handle is a %ReqManagedAgents.Provisioner.Environment.Handle{} struct
# (dot-access + Jason-encodes to %{environment_id: "env_id_…", name: "data_analysis_3f9a1b2c", digest: "3f9a1b2c"})

# Pin the current image as "prod" (movable pointer; retag freely):
:ok = Provisioner.tag("data_analysis", "prod", handle, store: store)

# Resolve the pinned image later — never falls back; {:error, :unknown_tag} on miss:
{:ok, %{environment_id: _env_id}} = Provisioner.resolve("data_analysis:prod", store: store)

# GC old versions — keep the newest 3 (plus any tagged digest; keep: has no default):
{:ok, %{archived: _old, kept: _live}} =
  Provisioner.prune_environments(client, "data_analysis", keep: 3, store: store)
```

`Store.File` persists handles and tags across OS processes (CLI tools, cron, mix tasks),
with atomic writes and a single-writer assumption. The default is `Store.ETS` — in-process
only. Values must be JSON-encodable (provision handles always are).

### Declared runtimes

Add a `runtimes:` key to the env spec to have the library produce a bootstrap script
and system-prompt instruction the agent runs on first need:

```elixir
env_spec = %{
  type: "cloud",
  packages: %{},
  networking: %{type: "unrestricted"},
  runtimes: [%{lang: :elixir, version: "1.20.2", via: :mise}]
}

{:ok, handle} = ReqManagedAgents.ensure_environment(client, env_spec, name: "myapp")
# handle.bootstrap == %{script: "…mise install script…", instructions: "…"}
```

Pass `handle.bootstrap.instructions` into your agent's system prompt. The agent runs
the bootstrap script once via bash before the first command that needs the runtime.
Proven end-to-end: ~11s on ubuntu-24.04 (precompiled OTP from mise; no compile step).
Only `via: :mise` is supported. The runtimes list is digest-covered — adding or changing
a runtime version produces a new image automatically, no extra machinery.

## Agents as managed entities

`ensure_agent/3` is the content-addressed cousin of `provision/3` ("Provision once, run
anywhere"): same `%Agent.Spec{}` vocabulary, but Store-backed, digest-named, tag- and
prune-aware, returning a typed handle you splat straight into `Session.run/2`.

The same content-addressed lifecycle `Provisioner.Environments` gives environments
applies to agents: `ReqManagedAgents.Agent.Spec` hashes an agent's identity
(`system_prompt`, `tools`, `terminal_tool`, `model_config` — `name` is the base, not
identity content); `ensure_agent/3` is build-if-absent, never re-creating on a hit;
tags are movable pointers; prune is explicit GC.

```elixir
agent_spec = %{
  name: "support_bot",
  system_prompt: "You triage support tickets.",
  tools: [],
  model_config: %{model: "claude-opus-4-6"}
}

# Build once — a second call with the same spec returns the same handle, no re-create:
{:ok, agent} = ReqManagedAgents.ensure_agent(client, agent_spec, name: "support_bot", store: store)
# agent is a %ReqManagedAgents.Agent.Handle{} struct
# (dot-access + Jason-encodes to %{agent_id: "agent_id_…", name: "support_bot_3f9a1b2c", digest: "3f9a1b2c"})

# Pin the current version as "prod" (movable; retag freely):
:ok = ReqManagedAgents.tag_agent("support_bot", "prod", agent, store: store)

# Resolve the pinned version later — {:error, :unknown_tag} on miss, never a silent fallback:
{:ok, agent} = ReqManagedAgents.resolve_agent("support_bot:prod", store: store)

# GC old versions — keep the newest 3 (plus any tagged digest; keep: has no default):
{:ok, %{archived: _old, kept: _live}} =
  ReqManagedAgents.prune_agents(client, "support_bot", keep: 3, store: store)
```

A 409 on create (a name collision on the provider side) recovers by name instead of
failing — the provider-side name is `<base>_<digest8>`, so a live agent with that exact
name IS this exact spec.

Pass the `ensure_agent/3` handle straight into `Session.run/2` alongside an environment
handle — `:agent`/`:environment` are unpacked to `:agent_id`/`:environment_id` before the
provider opens the session, so callers stop hand-threading raw ids:

```elixir
{:ok, env} = ReqManagedAgents.ensure_environment(client, env_spec, name: "data_analysis", store: store)

{:ok, result} =
  ReqManagedAgents.Session.run(ReqManagedAgents.Providers.ClaudeManagedAgents,
    agent: agent,
    environment: env,
    handler: MyTools,
    prompt: "Summarize this quarter's tickets"
  )
```

An explicit `:agent_id`/`:environment_id` still works and wins if both a handle and an
id are given.

## Using with Jido

The core is Jido-free. To use Jido Actions as tools, implement `handle_tool_call/3` by delegating
to `Jido.Action.Tool.execute_action/3`, and derive the tool definitions with
`Jido.Action.Tool.to_tool/1` (or `ReqManagedAgents.ToolSchema.to_custom_tool/3`). A dedicated
adapter package is planned.

## License

Apache-2.0.
