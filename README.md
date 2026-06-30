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
  [{:req_managed_agents, "~> 0.2"}]
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
{:ok, %{terminal: terminal, stop_reason: stop_reason, events: events}} =
  Session.run(ClaudeManagedAgents,
    client: ReqManagedAgents.new(), agent_id: agent_id, environment_id: env_id,
    prompt: "…", handler: MyHandler)

# AWS Bedrock AgentCore (request/response) — same handler, same result shape
{:ok, _} =
  Session.run(BedrockAgentCore,
    harness_arn: arn, runtime_session_id: sid, model: "bedrock:anthropic.claude-sonnet-4",
    prompt: "…", handler: MyHandler)
```

`terminal` (`:end_turn` / `:requires_action` / `:terminated`) is the **uniform** signal to branch
on. `stop_reason` is each provider's **raw native value** (a map for Claude, e.g.
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

See [`examples/local_tool_example.exs`](examples/local_tool_example.exs) for a complete Claude run
(agent + environment setup, plain-function handler) and
[`examples/provider_agnostic_example.exs`](examples/provider_agnostic_example.exs) for the same
handler driven against **both** providers.

## The Claude pattern (setup)

1. Create a versioned agent once (model, system prompt, custom-tool definitions); store its id.
2. Create an environment once with `Client.create_environment/2` and reuse its id (a session needs
   an `environment_id`).
3. Start a session; the provider drives the loop and emits `agent.custom_tool_use`. The library
   runs your tool via the `Handler` callback and posts the result back. On `end_turn`, you're done.

## The Bedrock AgentCore pattern (setup)

1. Provision a Harness once — CreateHarness + READY-poll, cached — via
   `ReqManagedAgents.Provisioner.ensure/2` (built on `ReqManagedAgents.AgentCore.Client`). Reuse its
   ARN.
2. `Session.run(BedrockAgentCore, harness_arn: …, runtime_session_id: …, …)`. Each turn is one
   synchronous signed invoke; resume re-sends the assistant `toolUse` + your `toolResult` delta.
   (`runtimeSessionId` must be ≥33 chars.)

## Layers

- `ReqManagedAgents.Provider` — the behaviour every backend implements (invocation + `normalize/1`).
- `ReqManagedAgents.Session` — the unified, supervised, reconnecting loop driven by your `Handler`.
- `ReqManagedAgents.Client` — Claude control-plane HTTP (agents, sessions, events, files).
- `ReqManagedAgents.SSE` / `.Stream` — the Claude event stream.
- `ReqManagedAgents.AgentCore.Client` / `.Converse` / `ReqManagedAgents.Provisioner` — Bedrock
  AgentCore wire client, Converse decoding, and Harness provisioning.
- `ReqManagedAgents.Event` / `.Consolidate` — pure builders, classification, reconnect helpers.
- `ReqManagedAgents.ToolSchema` — custom-tool schema construction.

## Telemetry

`req_managed_agents` emits `:telemetry` events you can attach to:

| Event | Measurements | Metadata |
|---|---|---|
| `[:req_managed_agents, :request, :start \| :stop \| :exception]` | `duration` | `method`, `path`, `status` |
| `[:req_managed_agents, :stream, :connected \| :event \| :done \| :error]` | — | `session_id`, `type`, `usage`, `reason` |
| `[:req_managed_agents, :tool, :start \| :stop \| :exception]` | `duration` | `tool`, `session_id`, `is_error` |
| `[:req_managed_agents, :session, :tool_uses]` | `tool_use_count` | `turn`, `tool_use_ids` |
| `[:req_managed_agents, :session, :terminal]` | — | `terminal` |

Both providers run through `Session`, so the `:session` events fire regardless of backend. Pass
`telemetry_metadata: %{…}` to merge custom tags (e.g. tenant) into every event; library-set keys
take precedence. `ReqManagedAgents.OpenTelemetry` bridges these to OTel GenAI spans.

## Files (Claude)

```elixir
{:ok, %{"id" => file_id}} = ReqManagedAgents.Client.upload_file(client, %{purpose: "agent", file: "report.csv"})
{:ok, _} = ReqManagedAgents.Client.attach_file_to_session(client, session_id, %{file_id: file_id, mount_path: "/data/report.csv"})
{:ok, bytes} = ReqManagedAgents.Client.download_file(client, file_id)
```

The Files API uses its own beta header (`files-api-2025-04-14`); `download_file/2` returns raw bytes.

## Using with Jido

The core is Jido-free. To use Jido Actions as tools, implement `handle_tool_call/3` by delegating
to `Jido.Action.Tool.execute_action/3`, and derive the tool definitions with
`Jido.Action.Tool.to_tool/1` (or `ReqManagedAgents.ToolSchema.to_custom_tool/3`). A dedicated
adapter package is planned.

## License

Apache-2.0.
