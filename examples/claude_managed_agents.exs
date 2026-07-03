# Claude Managed Agents: the full lifecycle, end to end.
#
# The headline pattern of this library: **the provider runs the agent loop;
# your custom tools execute here, on your node**. Anthropic only ever sees each
# tool's name, description, input schema, and the text result you return —
# your code and data never leave this process.
#
# What this script does:
#
#   1. creates a versioned agent (model + system prompt + custom-tool schema)
#   2. creates an environment for it to run in
#   3. asks it a question that requires the `lookup_customer` tool
#   4. Claude runs the loop server-side; when it calls the tool, control
#      returns HERE — `Demo.Handler.handle_tool_call/3` runs locally — and the
#      text result is posted back to resume the loop
#   5. prints the final `%ReqManagedAgents.SessionResult{}`: assistant text,
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

# The control-plane client. Reads ANTHROPIC_API_KEY from the environment by
# default; see `ReqManagedAgents.Client.new/1` for explicit options.
client = ReqManagedAgents.new()

# ── 1. Create the agent (one-time; store the id in a real app) ──────────────
#
# The agent is a versioned, provider-side resource: model, system prompt, and
# the SCHEMAS of your custom tools (never their implementations).
{:ok, %{"id" => agent_id}} =
  ReqManagedAgents.Client.create_agent(client, %{
    name: "billing-support",
    model: "claude-haiku-4-5",
    system: "You are a concise billing-support agent. Use tools for customer data.",
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
  })

IO.puts("created agent #{agent_id}")

# ── 2. Create an environment (also one-time; reuse the id) ──────────────────
{:ok, %{"id" => env_id}} =
  ReqManagedAgents.Client.create_environment(client, %{
    name: "billing-support-env",
    config: %{type: "cloud", networking: %{type: "unrestricted"}}
  })

# ── 3. Run a session to completion ──────────────────────────────────────────
#
# `run_to_completion/1` blocks until the agent reaches a terminal state and
# returns `{:ok, %ReqManagedAgents.SessionResult{}}`. It is the Claude
# convenience form of the provider-agnostic call:
#
#     ReqManagedAgents.Session.run(ReqManagedAgents.Providers.ClaudeManagedAgents, opts)
#
# For a long-lived, supervised, reconnecting session (a chat), use
# `ReqManagedAgents.start_session/1` + `ReqManagedAgents.Session.message/2`
# instead — same opts, same handler.
{:ok, result} =
  ReqManagedAgents.run_to_completion(
    client: client,
    agent_id: agent_id,
    environment_id: env_id,
    prompt: "What plan is jane@acme.com on, and when was she last billed?",
    handler: Demo.Handler
  )

# ── 4. The result: one canonical shape, whatever the provider ───────────────
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
