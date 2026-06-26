# ReqManagedAgents

The first Elixir client for [Anthropic's Claude Managed Agents](https://docs.anthropic.com) (public beta). Claude runs the agent loop server-side; **your custom tools execute locally**, so your data and code never leave your node — Anthropic only ever sees each tool's name, description, input schema, and the text result you return.

Beta header: `managed-agents-2026-04-01`.

## Install

```elixir
def deps do
  [{:req_managed_agents, "~> 0.1"}]
end
```

## The pattern

1. Create a versioned agent once (model, system prompt, custom-tool definitions); store its id.
2. Start a session; this needs an `environment_id`, so create an environment once with `Client.create_environment/2` and reuse it. Claude drives the loop and emits `agent.custom_tool_use`.
3. The library runs your tool locally via a `ReqManagedAgents.Handler` callback and posts the result back.
4. On `end_turn`, you're notified.

See `examples/local_tool_example.exs` for a complete runnable example using a plain-function handler.

For a one-shot synchronous run (no GenServer), use `ReqManagedAgents.run_to_completion/1`, which blocks until a terminal event and returns `{:ok, %{terminal:, stop_reason:, events:}}` (or `{:error, :timeout}`).

## Layers

- `ReqManagedAgents.Client` — control-plane HTTP (agents, sessions, events).
- `ReqManagedAgents.SSE` / `ReqManagedAgents.Stream` — the event stream.
- `ReqManagedAgents.Event` / `ReqManagedAgents.Consolidate` — pure builders, classification, reconnect helpers.
- `ReqManagedAgents.Session` — optional supervised loop driven by your `Handler`.

## Telemetry

`req_managed_agents` emits `:telemetry` events you can attach to:

| Event | Measurements | Metadata |
|---|---|---|
| `[:req_managed_agents, :request, :start \| :stop \| :exception]` | `duration` | `method`, `path`, `status` |
| `[:req_managed_agents, :stream, :connected \| :event \| :done \| :error]` | — | `session_id`, `type` (event), `usage`, `reason` (error) |
| `[:req_managed_agents, :tool, :start \| :stop \| :exception]` | `duration` | `tool`, `session_id`, `is_error` |
| `[:req_managed_agents, :session, :terminal]` | — | `terminal`, `session_id` |

Pass `telemetry_metadata: %{...}` to `start_session/1` or `run_to_completion/1` to merge custom tags (e.g. tenant) into every event. Library-set keys (`session_id`, `type`, `tool`, `terminal`) take precedence over your tags.

## Files

```elixir
{:ok, %{"id" => file_id}} = ReqManagedAgents.Client.upload_file(client, %{purpose: "agent", file: "report.csv"})
{:ok, _} = ReqManagedAgents.Client.attach_file_to_session(client, session_id, %{file_id: file_id, mount_path: "/data/report.csv"})
{:ok, bytes} = ReqManagedAgents.Client.download_file(client, file_id)
```

The Files API uses its own beta header (`files-api-2025-04-14`); `download_file/2` returns raw bytes.

## Using with Jido

The core is Jido-free. To use Jido Actions as tools, implement `handle_tool_call/3` by delegating to `Jido.Action.Tool.execute_action/3`, and derive the agent tool definitions with `Jido.Action.Tool.to_tool/1`. A dedicated adapter package is planned.

## License

Apache-2.0.
