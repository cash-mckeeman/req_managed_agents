# Headline pattern: a custom tool whose code + data never leave your node.
# Run with: ANTHROPIC_API_KEY=... mix run examples/local_tool_example.exs
#
# This uses a plain-function handler — no Jido. (For Jido, implement the same
# ReqManagedAgents.Handler callback by delegating to Jido.Action.Tool.execute_action/3.)

defmodule Demo.Handler do
  @behaviour ReqManagedAgents.Handler

  @impl true
  def handle_tool_call("lookup_customer", %{"email" => email}, _ctx) do
    # YOUR private DB; Claude never sees this code or the row.
    {:ok, "Customer #{email}: Pro plan, active, last invoice $49.00 on 2026-05-01."}
  end

  @impl true
  def handle_event(%{"type" => "agent.message"} = ev, _ctx) do
    IO.inspect(ev["content"], label: "assistant")
    :ok
  end

  def handle_event(_ev, _ctx), do: :ok
end

{:ok, _} = Application.ensure_all_started(:req_managed_agents)
client = ReqManagedAgents.new()

# One-time: create the agent (store the id in real apps).
{:ok, %{"id" => agent_id}} =
  ReqManagedAgents.Client.create_agent(client, %{
    name: "billing-support",
    model: "claude-opus-4-8",
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

IO.puts("Created agent #{agent_id}")

# Environments persist — create once and reuse (store the id), like the agent.
{:ok, %{"id" => env_id}} =
  ReqManagedAgents.Client.create_environment(client, %{
    name: "billing-support-env",
    config: %{type: "cloud", networking: %{type: "unrestricted"}}
  })

# One-shot question → blocks until the agent finishes. `run_to_completion/1` is the
# Claude convenience form of the provider-agnostic API; the explicit equivalent is
#
#     ReqManagedAgents.Session.run(ReqManagedAgents.Providers.ClaudeManagedAgents, opts)
#
# (`Demo.Handler.handle_event/2` still fires for each streamed event as it runs.)
# For a long-lived chat, use `ReqManagedAgents.start_session/1` (≡
# `Session.start_link(ClaudeManagedAgents, opts)`) + `ReqManagedAgents.Session.message/2`.
{:ok, %{terminal: terminal, stop_reason: stop_reason}} =
  ReqManagedAgents.run_to_completion(
    client: client,
    agent_id: agent_id,
    environment_id: env_id,
    prompt: "What plan is jane@acme.com on, and when was she last billed?",
    handler: Demo.Handler
  )

IO.puts("session finished: #{terminal} (#{inspect(stop_reason)})")
