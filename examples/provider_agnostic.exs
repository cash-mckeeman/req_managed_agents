# Provider-agnostic: ONE handler, ONE loop — the provider is a parameter.
#
# This is the library's core claim, demonstrated: `ReqManagedAgents.Session.run/2`
# drives ANY provider to completion and returns the same
# `%ReqManagedAgents.SessionResult{}`. Between backends, only two things
# change:
#
#   * the provider module (first argument)
#   * its connection opts (`:agent_id`/`:environment_id` for Claude;
#     `:harness_arn`/`:runtime_session_id` for AgentCore)
#
# Your tool handler, the result shape, the telemetry, and everything you build
# on top do not change. `result.terminal` is the uniform signal to branch on
# (`:end_turn` — finished normally; `:requires_action` — waiting on you;
# `:terminated` — stopped abnormally). `result.stop_reason` keeps each
# provider's raw native value (a map for Claude, a string for Bedrock) for
# when you need provider-specific detail.
#
# Prerequisites: resources provisioned on each backend you want to exercise —
# run examples/claude_managed_agents.exs and examples/bedrock_agent_core.exs
# first (or reuse existing ids), then:
#
#     ANTHROPIC_API_KEY=...  AGENT_ID=...  ENVIRONMENT_ID=... \
#     AWS_REGION=us-east-1   HARNESS_ARN=... \
#     mix run examples/provider_agnostic.exs

alias ReqManagedAgents.Session
alias ReqManagedAgents.Providers.{ClaudeManagedAgents, BedrockAgentCore}

defmodule Demo.Handler do
  @moduledoc false
  @behaviour ReqManagedAgents.Handler

  # Your private code + data; either provider only ever sees the text you
  # return. THIS EXACT MODULE serves both backends below, unchanged.
  @impl true
  def handle_tool_call("lookup_customer", %{"email" => email}, _ctx),
    do: {:ok, "Customer #{email}: Pro plan, active, last invoice $49.00 on 2026-05-01."}

  # Fires live on BOTH backends as events stream in mid-turn (observational,
  # at-least-once; `SessionResult.events` is the canonical record).
  @impl true
  def handle_event(_ev, _ctx), do: :ok
end

{:ok, _} = Application.ensure_all_started(:req_managed_agents)
prompt = "What plan is jane@acme.com on, and when was she last billed?"

# ── Backend A: Anthropic Claude Managed Agents (:streaming) ──────────────────
# A long-lived SSE stream pushes events; the client posts events to drive the
# loop. Connection opts are the agent + environment ids you provisioned.
claude_result =
  Session.run(ClaudeManagedAgents,
    client: ReqManagedAgents.new(),
    agent_id: System.fetch_env!("AGENT_ID"),
    environment_id: System.fetch_env!("ENVIRONMENT_ID"),
    prompt: prompt,
    handler: Demo.Handler
  )

# ── Backend B: AWS Bedrock AgentCore Harness (:request_response) ─────────────
# Each turn is one synchronous SigV4-signed invoke; the resume turn re-sends
# the assistant toolUse + your toolResult. Connection opts are the harness ARN
# (from provisioning) + a fresh session id (33–100 chars, [a-zA-Z0-9-_]).
# The model was fixed at provision time; pass `model:` only to override it.
bedrock_result =
  Session.run(BedrockAgentCore,
    harness_arn: System.fetch_env!("HARNESS_ARN"),
    runtime_session_id:
      "example-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
    prompt: prompt,
    handler: Demo.Handler
  )

# ── Same canonical result from both backends ─────────────────────────────────
for {label, result} <- [{"claude ", claude_result}, {"bedrock", bedrock_result}] do
  case result do
    {:ok, %ReqManagedAgents.SessionResult{} = r} ->
      IO.puts(
        "#{label}: #{r.terminal} in #{r.turns} turn(s), " <>
          "#{r.usage.input_tokens}/#{r.usage.output_tokens} tokens — #{String.slice(r.text, 0, 60)}"
      )

    {:error, reason} ->
      IO.puts("#{label}: error #{inspect(reason)}")
  end
end
