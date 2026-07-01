# Provisioning lifecycle smoke (run as an ExUnit test so Bypass works).
#
# Exercises the FULL provider-agnostic lifecycle end-to-end for BOTH providers —
# `provision → Session.run (one turn) → teardown` — with deterministic transports (the Bedrock
# seams + a Bypass control plane for Claude). Writes a per-provider lifecycle fingerprint to
# $QA_OUT. Driven by `mix req_managed_agents.qa_provisioning`, which reports PASS/FAIL.
#
# Run directly: QA_OUT=/tmp/prov.json mix test qa/provisioning_smoke_test.exs

defmodule QA.ProvisioningSmokeTest do
  use ExUnit.Case, async: false

  alias ReqManagedAgents.Session
  alias ReqManagedAgents.Providers.{BedrockAgentCore, ClaudeManagedAgents}

  setup do
    ReqManagedAgents.Provisioner.reset()
    :ok
  end

  test "provision → run → teardown lifecycle smoke for both providers" do
    results = [bedrock_lifecycle(), claude_lifecycle()]
    out = System.get_env("QA_OUT") || "qa_provisioning.json"
    File.write!(out, Jason.encode!(%{providers: results}))
  end

  defp spec(model_config),
    do: %{system_prompt: "be helpful", tools: [%{"name" => "echo"}], terminal_tool: nil, model_config: model_config}

  # ── Bedrock AgentCore: every hop is seam-injectable (no network) ──────────────────────
  defp bedrock_lifecycle do
    {:ok, calls} = Agent.start_link(fn -> %{created: nil, deleted: nil} end)

    create = fn hs ->
      Agent.update(calls, &Map.put(&1, :created, hs.name))
      {:ok, %{"harnessArn" => "arn:aws:bedrock-agentcore:us-east-1:0:harness/smoke", "harnessId" => "h-smoke"}}
    end

    get = fn _hid -> {:ok, %{"harness" => %{"status" => "READY"}}} end
    delete = fn hid -> Agent.update(calls, &Map.put(&1, :deleted, hid)); {:ok, %{}} end
    invoke = fn _inv ->
      {:ok,
       [
         %{"messageStop" => %{"stopReason" => "end_turn"}},
         %{"metadata" => %{"usage" => %{"inputTokens" => 42, "outputTokens" => 13, "totalTokens" => 55}}}
       ]}
    end

    {:ok, handle} =
      ReqManagedAgents.provision(BedrockAgentCore, spec(%{"bedrockModelConfig" => %{"modelId" => "anthropic.claude-sonnet-4"}}),
        execution_role_arn: "arn:aws:iam::1:role/R", create_fun: create, get_fun: get, ready_poll_ms: 0)

    {:ok, run} =
      Session.run(BedrockAgentCore,
        harness_arn: handle.harness_arn,
        runtime_session_id: String.duplicate("s", 33),
        prompt: "hi",
        handler: fn _n, _i, _c -> {:ok, "r"} end,
        invoke_fun: invoke)

    teardown = ReqManagedAgents.teardown(BedrockAgentCore, handle, delete_fun: delete)
    c = Agent.get(calls, & &1)

    %{
      provider: "bedrock",
      provisioned: is_binary(handle[:harness_arn]) and is_binary(handle[:harness_id]),
      resource_created: c.created,
      ran_terminal: to_string(run.terminal),
      usage_input: run.usage.input_tokens,
      usage_output: run.usage.output_tokens,
      teardown_ok: teardown == :ok,
      resource_deleted: c.deleted
    }
  end

  # ── Claude Managed Agents: Bypass stubs the control plane + SSE stream ────────────────
  defp claude_lifecycle do
    bypass = Bypass.open()
    client = ReqManagedAgents.Client.new(api_key: "sk-smoke", base_url: "http://localhost:#{bypass.port}")
    {:ok, archived} = Agent.start_link(fn -> [] end)

    Bypass.stub(bypass, "POST", "/v1/agents", fn conn -> Req.Test.json(conn, %{"id" => "agent-smoke"}) end)
    Bypass.stub(bypass, "POST", "/v1/environments", fn conn -> Req.Test.json(conn, %{"id" => "env-smoke"}) end)
    Bypass.stub(bypass, "POST", "/v1/sessions", fn conn -> Req.Test.json(conn, %{"id" => "sess-smoke"}) end)
    Bypass.stub(bypass, "POST", "/v1/sessions/sess-smoke/events", fn conn -> Req.Test.json(conn, %{"ok" => true}) end)

    Bypass.stub(bypass, "GET", "/v1/sessions/sess-smoke/events/stream", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      evs = [
        %{"type" => "span.model_request_end", "model_usage" => %{"input_tokens" => 37, "output_tokens" => 11}},
        %{"type" => "session.status_idle", "stop_reason" => %{"type" => "end_turn"}}
      ]

      chunk = Enum.map_join(evs, "", fn ev -> "event: #{ev["type"]}\ndata: #{Jason.encode!(ev)}\n\n" end)
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      conn
    end)

    Bypass.stub(bypass, "POST", "/v1/agents/agent-smoke/archive", fn conn ->
      Agent.update(archived, &["agent" | &1])
      Req.Test.json(conn, %{"ok" => true})
    end)

    Bypass.stub(bypass, "POST", "/v1/environments/env-smoke/archive", fn conn ->
      Agent.update(archived, &["environment" | &1])
      Req.Test.json(conn, %{"ok" => true})
    end)

    {:ok, handle} = ReqManagedAgents.provision(ClaudeManagedAgents, spec("claude-opus-4-8"), client: client)

    {:ok, run} =
      Session.run(ClaudeManagedAgents,
        client: client,
        agent_id: handle.agent_id,
        environment_id: handle.environment_id,
        prompt: "hi",
        handler: fn _n, _i, _c -> {:ok, "r"} end)

    teardown = ReqManagedAgents.teardown(ClaudeManagedAgents, handle, client: client)

    %{
      provider: "claude",
      provisioned: is_binary(handle[:agent_id]) and is_binary(handle[:environment_id]),
      resource_created: "#{handle[:agent_id]}+#{handle[:environment_id]}",
      ran_terminal: to_string(run.terminal),
      usage_input: run.usage.input_tokens,
      usage_output: run.usage.output_tokens,
      teardown_ok: teardown == :ok,
      resource_deleted: Enum.sort(Agent.get(archived, & &1))
    }
  end
end
