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
2. Start a session; Claude drives the loop and emits `agent.custom_tool_use`.
3. The library runs your tool locally via a `ReqManagedAgents.Handler` callback and posts the result back.
4. On `end_turn`, you're notified.

See `examples/local_tool_example.exs` for a complete runnable example using a plain-function handler.

## Layers

- `ReqManagedAgents.Client` — control-plane HTTP (agents, sessions, events).
- `ReqManagedAgents.SSE` / `ReqManagedAgents.Stream` — the event stream.
- `ReqManagedAgents.Event` / `ReqManagedAgents.Consolidate` — pure builders, classification, reconnect helpers.
- `ReqManagedAgents.Session` — optional supervised loop driven by your `Handler`.

## Using with Jido

The core is Jido-free. To use Jido Actions as tools, implement `handle_tool_call/3` by delegating to `Jido.Action.Tool.execute_action/3`, and derive the agent tool definitions with `Jido.Action.Tool.to_tool/1`. A dedicated adapter package is planned.

## License

Apache-2.0.
