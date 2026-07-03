# AWS Bedrock AgentCore Harness: provision → run → tear down.
#
# Same thesis as the Claude example — the provider runs the loop, your tools
# run here — but on AWS's managed runtime. AgentCore Harness is
# `:request_response`: each turn is one SigV4-signed `InvokeHarness` call, and
# a tool round-trip resumes the loop by re-sending the assistant `toolUse` +
# your `toolResult`.
#
# Requires the optional AWS deps (see the README install section):
#
#     {:ex_aws_auth, "~> 1.4"},
#     {:aws_event_stream, "~> 0.1"}
#
# Run it with AWS credentials in the environment (standard AWS_* vars; STS
# temporary credentials work — signing is session-token aware) plus the ARN of
# an execution role the harness will assume:
#
#     AWS_REGION=us-east-1 \
#     HARNESS_EXECUTION_ROLE_ARN=arn:aws:iam::<acct>:role/<your-exec-role> \
#     mix run examples/bedrock_agent_core.exs
#
# The execution role needs bedrock:InvokeModel* on your chosen model, plus the
# AgentCore logging/identity permissions — and note that the CALLER (you)
# needs CreateHarness/InvokeHarness AND the permissions AgentCore exercises on
# your behalf during creation (endpoint, workload identity, memory). Consult
# your AWS admin or the AgentCore docs for the full matrix.

defmodule Demo.Handler do
  @moduledoc false
  @behaviour ReqManagedAgents.Handler

  @impl true
  def handle_tool_call("lookup_customer", %{"email" => email}, _ctx),
    do: {:ok, "Customer #{email}: Pro plan, active, last invoice $49.00 on 2026-05-01."}

  @impl true
  def handle_event(_ev, _ctx), do: :ok
end

{:ok, _} = Application.ensure_all_started(:req_managed_agents)

alias ReqManagedAgents.Providers.BedrockAgentCore

# ── 1. Provision the harness (idempotent; cached per {provider, spec}) ──────
#
# The spec is the provider-agnostic shape from `ReqManagedAgents.Provider`:
# system prompt, tool schemas, and a provider-native model config. The tool
# entries use AgentCore's wire format (`inline_function`); only the SCHEMA
# ships — the implementation stays in your Handler.
#
# `provision/3` is create-or-reuse: it survives name collisions with an
# existing READY harness and polls until the harness is READY (creation takes
# a minute or two). Store the returned handle in a real app.
spec = %{
  system_prompt: "You are a concise billing-support agent. Use tools for customer data.",
  terminal_tool: nil,
  model_config: %{
    # Anthropic models on Bedrock must use the cross-region inference profile
    # id (`us.`-prefixed) — the bare model id has no in-region support.
    "bedrockModelConfig" => %{"modelId" => "us.anthropic.claude-haiku-4-5-20251001-v1:0"}
  },
  tools: [
    %{
      "type" => "inline_function",
      "name" => "lookup_customer",
      "config" => %{
        "inlineFunction" => %{
          "description" =>
            "Look up a customer by email and return plan, status, and last invoice. " <>
              "Always call this for customer data; never guess.",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"email" => %{"type" => "string"}},
            "required" => ["email"]
          }
        }
      }
    }
  ]
}

{:ok, handle} =
  ReqManagedAgents.provision(BedrockAgentCore, spec,
    execution_role_arn: System.fetch_env!("HARNESS_EXECUTION_ROLE_ARN"),
    name_prefix: "example"
  )

IO.puts("provisioned harness #{handle.harness_id}")

# ── 2. Run a session — the provider-agnostic entrypoint ─────────────────────
#
# Note the AgentCore session-id contract: 33–100 chars, [a-zA-Z0-9-_].
{:ok, result} =
  ReqManagedAgents.Session.run(BedrockAgentCore,
    harness_arn: handle.harness_arn,
    runtime_session_id:
      "example-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
    prompt: "What plan is jane@acme.com on, and when was she last billed?",
    handler: Demo.Handler
  )

IO.puts("""

terminal: #{result.terminal}
turns:    #{result.turns}
tokens:   #{result.usage.input_tokens} in / #{result.usage.output_tokens} out

#{result.text}
""")

# ── 3. Tear down (AgentCore deletion is async and takes minutes) ────────────
#
# In a real app you'd keep the harness and reuse it — provisioning is the
# expensive part. This example cleans up after itself. Note: re-provisioning
# the same spec immediately after teardown can hit a name conflict while the
# old harness is still DELETING.
:ok = ReqManagedAgents.teardown(BedrockAgentCore, handle)
IO.puts("teardown requested (deletion completes asynchronously)")
