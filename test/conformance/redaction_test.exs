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
