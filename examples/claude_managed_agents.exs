# Claude Managed Agents: the full lifecycle, end to end.
#
# The headline pattern of this library: **the provider runs the agent loop;
# your custom tools execute here, on your node**. Anthropic only ever sees each
# tool's name, description, input schema, and the text result you return —
# your code and data never leave this process.
#
# What this script does:
#
#   1. provisions a versioned agent + its environment in one call
#      (`provision/3` — model + system prompt + custom-tool schema, plus the
#      environment the session runs in)
#   2. asks it a question that requires the `lookup_customer` tool
#   3. Claude runs the loop server-side; when it calls the tool, control
#      returns HERE — `Demo.Handler.handle_tool_call/3` runs locally — and the
#      text result is posted back to resume the loop
#   4. prints the final `%ReqManagedAgents.SessionResult{}`: assistant text,
#      terminal, and token usage
#
# Run it:
#
#     ANTHROPIC_API_KEY=sk-ant-... mix run examples/claude_managed_agents.exs
#
# Cost: one short Haiku-class conversation (a fraction of a cent on the
# default model below). Agents and environments are free to create and
# persist until deleted.

defmodule Demo.Handler do
  @moduledoc false
  @behaviour ReqManagedAgents.Handler

  # Called whenever the agent invokes one of YOUR custom tools. This is the
  # return-of-control seam: the function body is private to your node — query
  # your database, call internal services, whatever. Only the returned text
  # goes back to the provider. Return `{:error, text}` to post a tool failure
  # (the agent sees it flagged `is_error` and can recover).
  @impl true
  def handle_tool_call("lookup_customer", %{"email" => email}, _ctx) do
    # Pretend this is your private DB. Claude never sees this code or the row.
    {:ok, "Customer #{email}: Pro plan, active, last invoice $49.00 on 2026-05-01."}
  end

  # Optional: observe every streamed event as the loop runs (assistant
  # messages, tool activity, lifecycle). Great for logging/UX; return :ok.
  @impl true
  def handle_event(%{"type" => "agent.message"} = ev, _ctx) do
    IO.puts("assistant> #{inspect(ev["content"])}")
    :ok
  end

  def handle_event(_ev, _ctx), do: :ok
end

{:ok, _} = Application.ensure_all_started(:req_managed_agents)

alias ReqManagedAgents.Agent.Spec
alias ReqManagedAgents.Providers.ClaudeManagedAgents

# The control-plane client. Reads ANTHROPIC_API_KEY from the environment by
# default; see `ReqManagedAgents.Client.new/1` for explicit options.
client = ReqManagedAgents.new()

# ── 1. Provision the agent + environment (idempotent; cached per {provider, spec}) ──
#
# The same shape as the Bedrock example: build an `%Agent.Spec{}` — name,
# system prompt, and the SCHEMAS of your custom tools (never their
# implementations) — and hand it to `ReqManagedAgents.provision/3`, with the
# environment passed as the `:environment` option (an `Environment.Spec`, or a
# flat map that coerces to one — its `config` is passed verbatim to the wire
# environment field). For Claude Managed Agents the model config is a plain
# model-id string. `provision/3` creates the versioned agent resource and its
# environment, returning ONE handle carrying both ids. Store it in a real app.
agent_spec = %Spec{
  name: "billing-support",
  system_prompt: "You are a concise billing-support agent. Use tools for customer data.",
  model_config: "claude-haiku-4-5",
  tools: [
    %{
      type: "custom",
      name: "lookup_customer",
      description:
        "Look up a customer by email and return plan, status, and last invoice. " <>
          "Always call this for customer data; never guess.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"email" => %{"type" => "string"}},
        "required" => ["email"]
      }
    }
  ]
}

env_spec = %{type: "cloud", networking: %{type: "unrestricted"}}

{:ok, handle} =
  ReqManagedAgents.provision(ClaudeManagedAgents, agent_spec,
    client: client,
    environment: env_spec
  )

# handle == %{agent_id: "agent_id_…", environment_id: "env_id_…"}
IO.puts("provisioned agent #{handle.agent_id}")

# ── 2. Run a session to completion ──────────────────────────────────────────
#
# `Session.run/2` blocks until the agent reaches a terminal state and returns
# `{:ok, %ReqManagedAgents.SessionResult{}}`. The provision handle carries both
# ids; `:agent`/`:environment` accept it directly (each lifts the id it needs),
# so you never hand-thread raw ids.
#
# For a long-lived, supervised, reconnecting session (a chat), use
# `ReqManagedAgents.start_session/1` + `ReqManagedAgents.Session.message/2`
# instead — same opts, same handler. `ReqManagedAgents.run_to_completion/1` is
# the Claude convenience alias for `Session.run(ClaudeManagedAgents, opts)`.
{:ok, result} =
  ReqManagedAgents.Session.run(ClaudeManagedAgents,
    client: client,
    agent: handle,
    environment: handle,
    prompt: "What plan is jane@acme.com on, and when was she last billed?",
    handler: Demo.Handler
  )

# ── 3. The result: one canonical shape, whatever the provider ───────────────
#
#   result.terminal  — :end_turn | :requires_action | :terminated
#   result.text      — the assistant's accumulated text
#   result.usage     — %ReqManagedAgents.Usage{input_tokens:, output_tokens:, ...}
#   result.turns     — how many loop turns the provider ran
#   result.custom_tool_uses — every return-of-control tool call it made
#   result.events    — the raw provider events, if you need them
IO.puts("""

terminal: #{result.terminal}
turns:    #{result.turns}
tokens:   #{result.usage.input_tokens} in / #{result.usage.output_tokens} out
tools:    #{Enum.map_join(result.custom_tool_uses, ", ", & &1.name)}

#{result.text}
""")
