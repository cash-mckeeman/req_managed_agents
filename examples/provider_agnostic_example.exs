# Provider-agnostic: ONE handler, ONE loop — the provider is a parameter.
#
# `ReqManagedAgents.Session.run/2` drives ANY provider to completion and returns the SAME
# `{:ok, %{terminal:, stop_reason:, events:}}` shape. Only the first argument (the provider
# module) and its connection opts change between backends; your tool handler and the result
# shape do not. `terminal` (`:end_turn` / `:requires_action` / `:terminated`) is the uniform
# signal to branch on; `stop_reason` is each provider's raw native value (a map for Claude, a
# string for Bedrock).
#
# Run with the relevant credentials/ids set (see the setup comments under each backend).

alias ReqManagedAgents.Session
alias ReqManagedAgents.Providers.{ClaudeManagedAgents, BedrockAgentCore}

defmodule Demo.Handler do
  @behaviour ReqManagedAgents.Handler

  # Your private code + data; the provider only ever sees the text you return.
  @impl true
  def handle_tool_call("lookup_customer", %{"email" => email}, _ctx),
    do: {:ok, "Customer #{email}: Pro plan, active, last invoice $49.00 on 2026-05-01."}

  @impl true
  def handle_event(_ev, _ctx), do: :ok
end

{:ok, _} = Application.ensure_all_started(:req_managed_agents)
prompt = "What plan is jane@acme.com on, and when was she last billed?"

# ── Backend A: Anthropic Claude Managed Agents (:streaming) ────────────────────────────
# A long-lived SSE stream pushes events; the client POSTs events to drive the loop.
# Setup once (see local_tool_example.exs): create a versioned agent carrying the
# `lookup_customer` custom-tool definition + an environment; reuse their ids.
claude_result =
  Session.run(ClaudeManagedAgents,
    client: ReqManagedAgents.new(),
    agent_id: System.fetch_env!("AGENT_ID"),
    environment_id: System.fetch_env!("ENVIRONMENT_ID"),
    prompt: prompt,
    handler: Demo.Handler
  )

# ── Backend B: AWS Bedrock AgentCore Harness (:request_response) ───────────────────────
# Each turn is one synchronous SigV4-signed invoke; resume re-sends the assistant toolUse +
# user toolResult delta. Setup once: provision a Harness (CreateHarness + READY-poll) and
# reuse its ARN — see `ReqManagedAgents.Provisioner.ensure/2`. runtimeSessionId must be ≥33 chars.
bedrock_result =
  Session.run(BedrockAgentCore,
    harness_arn: System.fetch_env!("HARNESS_ARN"),
    runtime_session_id:
      "demo-session-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
    model: "bedrock:anthropic.claude-sonnet-4",
    prompt: prompt,
    handler: Demo.Handler
  )

# ── Same canonical result from both backends ───────────────────────────────────────────
for {label, result} <- [{"claude ", claude_result}, {"bedrock", bedrock_result}] do
  case result do
    {:ok, %{terminal: t, stop_reason: sr}} -> IO.puts("#{label}: #{t} (#{inspect(sr)})")
    {:error, reason} -> IO.puts("#{label}: error #{inspect(reason)}")
  end
end
