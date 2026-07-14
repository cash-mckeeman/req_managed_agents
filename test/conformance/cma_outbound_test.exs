defmodule ReqManagedAgents.Conformance.CmaOutboundTest do
  @moduledoc """
  Outbound conformance for Claude Managed Agents' `provision/2`: the
  `create_agent` + `create_environment` wire bodies RMA builds are (1)
  golden-matched against the pinned corpus, and (2) — the highest-value case —
  carry the BARE model id. That's the exact class of bug issue #65 caught: CMA
  rejects a provider-qualified model id like `"anthropic:claude-sonnet-4-6"`;
  only the bare `"claude-sonnet-4-6"` may reach the wire.

  No botocore/JSON-schema model exists for CMA (Anthropic-hosted, not AWS), so
  this is golden-match + a targeted assertion only — no `Schema.validate`.

  All fixtures here are synthetic (fake `sk-test` key, Bypass-backed
  endpoints) so every test in this module runs in public CI, not just against
  the private `RMA_CORPUS_DIR` corpus.
  """
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Client
  alias ReqManagedAgents.Conformance.{Corpus, Redaction}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents

  test "create_agent body carries the BARE model id (#65)" do
    %{"create_agent" => body} =
      capture_provision_bodies(spec_with_model("anthropic:claude-sonnet-4-6"), [])

    assert body["model"] == "claude-sonnet-4-6"
  end

  test "each CMA request golden matches the redacted body RMA builds" do
    # provision/2 names the agent/environment off opts[:name] (falling back to a
    # content digest) — pin it so the captured bodies line up with the synthetic
    # goldens' "example-agent" / "example-agent_env" names byte-for-byte.
    captured = capture_provision_bodies(canonical_spec(), name: "example-agent")

    for %Corpus.Entry{name: name, json: golden} <- Corpus.entries(:cma, :requests) do
      wire = Map.fetch!(captured, name)
      assert Redaction.redact(wire) == golden, "golden drift: #{name}"
    end
  end

  defp canonical_spec do
    %{
      name: "conformance-agent",
      system_prompt: "You are a helpful assistant.",
      model_config: "claude-sonnet-4-6",
      tools: []
    }
  end

  defp spec_with_model(model_config) do
    %{
      name: "conformance-agent",
      system_prompt: "sys",
      model_config: model_config,
      tools: []
    }
  end

  # Captures the exact create_agent + create_environment wire bodies
  # `provision/2` POSTs, without touching the network: Bypass stubs both
  # endpoints, decodes each POST body, and hands both back keyed by request
  # name (matching the golden filenames create_agent / create_environment).
  defp capture_provision_bodies(spec, opts) do
    test_pid = self()
    bypass = Bypass.open()
    client = Client.new(api_key: "sk-test", base_url: "http://localhost:#{bypass.port}")

    Bypass.expect_once(bypass, "POST", "/v1/agents", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:wire_body, "create_agent", Jason.decode!(raw)})
      Req.Test.json(conn, %{"id" => "agent_x"})
    end)

    Bypass.expect_once(bypass, "POST", "/v1/environments", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:wire_body, "create_environment", Jason.decode!(raw)})
      Req.Test.json(conn, %{"id" => "env_x"})
    end)

    assert {:ok, %{agent_id: "agent_x", environment_id: "env_x"}} =
             ClaudeManagedAgents.provision(spec, [client: client] ++ opts)

    assert_receive {:wire_body, "create_agent", agent_body}
    assert_receive {:wire_body, "create_environment", env_body}

    %{"create_agent" => agent_body, "create_environment" => env_body}
  end
end
