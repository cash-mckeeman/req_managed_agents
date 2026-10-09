defmodule ReqManagedAgents.BedrockNamespaceCompatibilityTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.AgentCore.CommandResult, as: OldResult
  alias ReqManagedAgents.Providers.BedrockAgentCore.Artifacts
  alias ReqManagedAgents.Providers.BedrockAgentCore.CommandResult, as: Result

  test "legacy and canonical clients retain options and redact credentials" do
    credentials = %{
      access_key_id: "AKID",
      secret_access_key: "private-fixture",
      region: "us-east-1",
      security_token: "session-fixture"
    }

    canonical = ReqManagedAgents.Providers.BedrockAgentCore.Client
    legacy = ReqManagedAgents.AgentCore.Client

    transport = fn conn ->
      assert conn.request_path == "/harnesses/test"
      Req.Test.json(conn, %{harnessId: "test"})
    end

    for mod <- [canonical, legacy] do
      client =
        mod.new(
          credentials: credentials,
          receive_timeout: 123,
          req_options: [plug: transport, retry: false]
        )

      assert client.__struct__ == mod
      assert client.credentials === credentials
      assert client.receive_timeout == 123
      refute inspect(client) =~ "private-fixture"
      refute inspect(client) =~ "session-fixture"

      for caller <- [canonical, legacy] do
        assert {:ok, %{"harnessId" => "test"}} = caller.get_harness(client, "test")
      end
    end
  end

  test "artifact stores accept both result types and old facade preserves nested identity" do
    for result <- [
          struct(OldResult, stderr: "failed", exit_code: 7),
          struct(Result, stderr: "failed", exit_code: 7)
        ] do
      for mod <- [Artifacts, ReqManagedAgents.Artifacts.AgentCoreSessionStorage] do
        store =
          mod.store(:injected, "arn:runtime", "session", "/mnt/data",
            command_fun: fn _ -> {:ok, result} end
          )

        expected = if mod == Artifacts, do: Result, else: OldResult

        for outcome <- [
              mod.list(store),
              mod.fetch(store, "a"),
              mod.put(store, "a", "contents"),
              mod.delete(store, "a")
            ] do
          assert {:error, {:command_failed, failed}} = outcome
          assert failed.__struct__ == expected
          assert failed.stderr == "failed"
          assert failed.exit_code == 7
        end
      end
    end
  end

  test "command JSON shape survives the namespace boundary" do
    assert Jason.encode!(struct(OldResult, stdout: "a", stderr: "b", exit_code: 3)) ==
             Jason.encode!(struct(Result, stdout: "a", stderr: "b", exit_code: 3))
  end
end
