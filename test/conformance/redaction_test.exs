defmodule ReqManagedAgents.Conformance.RedactionTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Conformance.Redaction

  test "redact/1 rewrites bearer tokens, access keys, and account digits to stable placeholders" do
    input = %{
      "authorization" => "Bearer sk-live-abc123",
      "executionRoleArn" => "arn:aws:iam::123456789012:role/Prod",
      "accessKeyId" => "AKIAIOSFODNN7EXAMPLE",
      "sessionId" => "sess-9f8e7d",
      "nested" => %{"messages" => [%{"text" => "hi"}]}
    }

    out = Redaction.redact(input)
    assert out["authorization"] == "Bearer ***"
    assert out["executionRoleArn"] == "arn:aws:iam::000000000000:role/Prod"
    refute out["accessKeyId"] =~ "AKIA"
    assert out["sessionId"] == "sess-REDACTED"
    assert out["nested"]["messages"] == [%{"text" => "hi"}]
  end

  test "redact/1 covers extended + case-insensitive credential keys (apiKey, PascalCase AWS, bare id)" do
    input = %{
      "apiKey" => "sk-live-abcdef1234567890",
      "SecretAccessKey" => "wJalrXUtnFEMI",
      "SessionToken" => "FQoGZ",
      "id" => "agent_abc123",
      "modelId" => "anthropic.claude-sonnet-4-6"
    }

    out = Redaction.redact(input)
    assert out["apiKey"] == "REDACTED"
    assert out["SecretAccessKey"] == "REDACTED"
    assert out["SessionToken"] == "REDACTED"
    assert out["id"] == "REDACTED"
    # `modelId` is not an id key — only a whole-key match on "id" redacts.
    assert out["modelId"] == "anthropic.claude-sonnet-4-6"
  end

  test "scan/1 flags ASIA temp keys and sk- bearer secrets across any file extension" do
    dir = Path.join(System.tmp_dir!(), "rma_scan_extended")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.json"), ~s({"blob":"ASIAABCDEFGHIJKLMNOP"}))
    # A non-{json,bin,sse} extension must still be scanned.
    File.write!(Path.join(dir, "b.ndjson"), ~s({"t":"sk-ant-abcdefghijklmnopqrstuvwxyz"}))

    assert {:leak, leaks} = Redaction.scan(dir)
    assert length(leaks) == 2
  after
    File.rm_rf!(Path.join(System.tmp_dir!(), "rma_scan_extended"))
  end

  test "scan/1 flags a leaked secret pattern in a committed fixture dir" do
    dir = Path.join(System.tmp_dir!(), "rma_scan_leak")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "bad.json"),
      ~s({"executionRoleArn":"arn:aws:iam::123456789012:role/R"})
    )

    assert {:leak, [_ | _]} = Redaction.scan(dir)
  after
    File.rm_rf!(Path.join(System.tmp_dir!(), "rma_scan_leak"))
  end

  test "scan/1 is :ok for the clean synthetic agentcore examples" do
    assert :ok == Redaction.scan(Path.expand(Path.join([__DIR__, "examples", "agentcore"])))
  end

  test "all committed example fixtures are secret-free" do
    for surface <- ~w(agentcore cma) do
      dir = Path.expand(Path.join([__DIR__, "examples", surface]))
      if File.dir?(dir), do: assert(:ok == Redaction.scan(dir), "leak in #{surface} examples")
    end
  end
end
