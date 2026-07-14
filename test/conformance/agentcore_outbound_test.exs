defmodule ReqManagedAgents.Conformance.AgentcoreOutboundTest do
  @moduledoc """
  Outbound conformance for AgentCore `CreateHarness`: the wire body RMA builds
  is (1) schema-valid against the botocore input shape, (2) golden-matches the
  pinned corpus, and (3) — the highest-value case — carries `environment`
  VERBATIM. That last one is the exact class of bug the v0.9.0 live-canary
  caught: `opts[:environment]` must reach the wire `"environment"` field
  byte-for-byte, with no per-key indexing.

  All fixtures here are synthetic (account `000000000000`, fake Bypass
  credentials) so every test in this module runs in public CI, not just
  against the private `RMA_CORPUS_DIR` corpus.
  """
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Agent.Spec
  alias ReqManagedAgents.AgentCore.Client
  alias ReqManagedAgents.Conformance.{Corpus, Redaction, Schema}
  alias ReqManagedAgents.Providers.BedrockAgentCore

  # Fake Bypass credentials — never real AWS creds. Same shape as
  # AgentCore.ClientTest's `@creds`.
  @creds %{
    access_key_id: "AKID",
    secret_access_key: "secret",
    region: "us-east-1",
    security_token: nil
  }

  @role "arn:aws:iam::000000000000:role/ConformanceRole"

  @env %{
    "agentCoreRuntimeEnvironment" => %{
      "filesystemConfigurations" => [%{"sessionStorage" => %{"mountPath" => "/mnt/data"}}]
    }
  }

  test "the CreateHarness body RMA builds validates against the botocore input shape" do
    wire = capture_create_harness(canonical_spec(), execution_role_arn: @role)
    assert :ok == Schema.validate(wire, Corpus.load(:agentcore, :model, "create_harness").json)
  end

  test "environment is passed VERBATIM to the wire (v0.9.0 regression guard)" do
    wire = capture_create_harness(canonical_spec(), execution_role_arn: @role, environment: @env)

    # The exact bug the live-canary caught: no per-key indexing, no coercion — verbatim.
    assert wire["environment"] == @env
  end

  test "each golden request matches the redacted body RMA builds" do
    for %Corpus.Entry{name: name, json: golden} <- Corpus.entries(:agentcore, :requests) do
      wire = wire_for(name)
      assert Redaction.redact(wire) == golden, "golden drift: #{name}"
    end
  end

  defp wire_for("create_harness_with_env"),
    do: capture_create_harness(canonical_spec(), execution_role_arn: @role, environment: @env)

  defp wire_for("create_harness"),
    do: capture_create_harness(canonical_spec(), execution_role_arn: @role)

  defp wire_for(name), do: flunk("no wire builder registered for golden fixture #{inspect(name)}")

  defp canonical_spec do
    %Spec{
      name: "conformance-agent",
      system_prompt: "You are a helpful assistant.",
      model_config: %{"bedrockModelConfig" => %{"modelId" => "anthropic.claude-sonnet-4-6"}},
      tools: []
    }
  end

  # Captures the exact CreateHarness wire body RMA POSTs, without touching the
  # network: `build_spec/2` assembles the real HarnessSpec, `create_harness/2`
  # signs and POSTs it to a Bypass-backed control endpoint, and the Bypass
  # handler decodes+forwards the raw body back to this test process.
  # `create_harness/2` alone (not `BedrockAgentCore.do_provision/2`) is what's
  # under test here — the READY-poll lives in `do_provision`, so calling
  # `create_harness/2` directly captures the CreateHarness body cleanly with a
  # single Bypass expectation.
  defp capture_create_harness(spec, opts) do
    test_pid = self()
    bypass = Bypass.open()
    client = Client.new(credentials: @creds, base_url: "http://localhost:#{bypass.port}")

    Bypass.expect_once(bypass, "POST", "/harnesses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:wire_body, Jason.decode!(raw)})

      Plug.Conn.resp(
        conn,
        200,
        ~s({"harness":{"arn":"arn:aws:bedrock-agentcore:us-east-1:000000000000:harness/x","harnessId":"x","status":"READY"}})
      )
    end)

    {:ok, harness_spec} = BedrockAgentCore.build_spec(spec, opts)
    {:ok, _} = Client.create_harness(client, harness_spec)

    assert_receive {:wire_body, wire}
    wire
  end
end
