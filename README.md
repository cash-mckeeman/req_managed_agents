# ReqManagedAgents

An Elixir client for **provider-managed agent loops with locally-executed tools**. The provider
runs the agent loop; **your custom tools execute on your node**, so your code and data never leave
it — the provider only ever sees each tool's name, description, input schema, and the text result
you return.

One loop, two backends behind a single `Provider` behaviour:

| Provider | Module | Transport |
|---|---|---|
| **Anthropic Claude Managed Agents** (public beta) | `ReqManagedAgents.Providers.ClaudeManagedAgents` | `:streaming` — long-lived SSE; beta header `managed-agents-2026-04-01` |
| **AWS Bedrock AgentCore Harness** | `ReqManagedAgents.Providers.BedrockAgentCore` | `:request_response` — synchronous SigV4-signed invoke |

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

## The core: one loop, the provider is a parameter

`ReqManagedAgents.Session` is the unified loop — invoke a turn → run your return-of-control tools
locally → resume → repeat — parameterized by a provider module. It returns the **same** result
shape for every provider:

```elixir
alias ReqManagedAgents.Session
alias ReqManagedAgents.Providers.{ClaudeManagedAgents, BedrockAgentCore}

# Claude Managed Agents (streaming)
{:ok, %ReqManagedAgents.SessionResult{} = result} =
  Session.run(ClaudeManagedAgents,
    client: ReqManagedAgents.new(), agent_id: agent_id, environment_id: env_id,
    prompt: "…", handler: MyHandler)

result.terminal   # :end_turn | :requires_action | :terminated — uniform across providers
result.text       # the assistant's accumulated text
result.usage      # %ReqManagedAgents.Usage{input_tokens:, output_tokens:, …}

# AWS Bedrock AgentCore (request/response) — same handler, same result struct
{:ok, %ReqManagedAgents.SessionResult{}} =
  Session.run(BedrockAgentCore,
    harness_arn: arn, runtime_session_id: sid,
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
  lifecycle: agent + environment setup, a local tool handler, and the
  `%SessionResult{}` (text, terminal, token usage).
- [`examples/bedrock_agent_core.exs`](examples/bedrock_agent_core.exs) — AgentCore Harness:
  `provision/3` (idempotent, READY-polled), `Session.run/2`, `teardown/2`, and the AWS
  gotchas (session-id contract, cross-region model profiles, async deletion).
- [`examples/provider_agnostic.exs`](examples/provider_agnostic.exs) — the core claim: one
  handler, one loop, two providers, same result shape.

## The Claude pattern (setup)

1. Create a versioned agent once (model, system prompt, custom-tool definitions); store its id.
2. Create an environment once with `Client.create_environment/2` and reuse its id (a session needs
   an `environment_id`).
3. Start a session; the provider drives the loop and emits `agent.custom_tool_use`. The library
   runs your tool via the `Handler` callback and posts the result back. On `end_turn`, you're done.

## The Bedrock AgentCore pattern (setup)

1. Provision a Harness once — CreateHarness + READY-poll, idempotent and cached — via
   `ReqManagedAgents.provision/3` (`Provisioner.ensure/3` under the hood, built on
   `ReqManagedAgents.AgentCore.Client`). Store the returned handle; tear down with
   `ReqManagedAgents.teardown/2`.
2. `Session.run(BedrockAgentCore, harness_arn: …, runtime_session_id: …, …)`. Each turn is one
   synchronous signed invoke; resume re-sends the assistant `toolUse` + your `toolResult` delta.
   (`runtimeSessionId` must be ≥33 chars.)
   Long runs: pass `idle_timeout:` (inter-chunk liveness guard, default 300s — the turn
   itself has **no client wall clock**) and the server budgets `timeout_seconds:`,
   `max_iterations:`, `max_tokens:` (per-invocation overrides of the harness defaults).
   Note: `Session.run/2`'s `:timeout` must be ≥ the server budget — a client timeout returns
   `{:error, :timeout}` but does NOT cancel the in-flight invoke; the harness keeps executing
   (and billing) server-side up to its own `timeoutSeconds`.
   Events stream to your `Handler.handle_event/2` live as the turn runs.

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
| `[:req_managed_agents, :stream, :connected \| :event \| :done \| :error]` | — | `session_id`, `type`, `usage`, `reason` |
| `[:req_managed_agents, :tool, :start \| :stop \| :exception]` | `duration` | `tool`, `session_id`, `is_error` |
| `[:req_managed_agents, :session, :tool_uses]` | `tool_use_count` | `turn`, `tool_use_ids` |
| `[:req_managed_agents, :session, :terminal]` | — | `terminal` |

Both providers run through `Session`, so the `:session` events fire regardless of backend.
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
Declare mounts via the opaque `environment` field on the provision spec.

> **The outputs-dir convention (Claude Managed Agents, established live 2026-07-03):**
> only files the agent writes under **`/mnt/session/outputs/`** become session
> artifacts — scoped to the session, downloadable, retrievable via `ClaudeFiles`.
> Files written elsewhere (e.g. `/workspace`) leave non-downloadable, unscoped
> residue. The path is exposed as `ClaudeFiles.outputs_dir/0` (+
> `output_path/1` for a named file) — interpolate it into your agent's system
> prompt instead of copying the string.

## Using with Jido

The core is Jido-free. To use Jido Actions as tools, implement `handle_tool_call/3` by delegating
to `Jido.Action.Tool.execute_action/3`, and derive the tool definitions with
`Jido.Action.Tool.to_tool/1` (or `ReqManagedAgents.ToolSchema.to_custom_tool/3`). A dedicated
adapter package is planned.

## License

Apache-2.0.
