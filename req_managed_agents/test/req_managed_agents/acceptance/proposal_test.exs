defmodule ReqManagedAgents.Acceptance.ProposalTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Rma.Acceptance, as: Command
  alias ReqManagedAgents.Acceptance
  alias ReqManagedAgents.Acceptance.Config

  def config do
    %{
      "schema_version" => 1,
      "provider" => "agentcore",
      "scenario" => "basic",
      "resource" => %{
        "reference" => "arn:aws:bedrock-agentcore:us-east-1:000000000000:harness/invented",
        "region" => "us-east-1",
        "runtime_session_id" => String.duplicate("a", 33)
      },
      "source_revision" => String.duplicate("a", 40),
      "retain_until" => "2099-01-01T00:00:00Z",
      "content" => "drop",
      "bounds" => %{"calls" => 1, "records" => 100, "bytes" => 100_000, "timeout_ms" => 1000},
      "inputs" => %{
        "prompt" => "Say hello",
        "model" => nil,
        "max_tokens" => 16,
        "timeout_seconds" => 1
      }
    }
  end

  test "proposal binds exact bytes and explicitly selected resource without execution" do
    bytes = Jason.encode!(config())
    assert {:ok, parsed} = Config.parse(bytes)
    assert {:ok, proposal} = Acceptance.propose(parsed)
    assert proposal.config_digest == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert proposal.resource == parsed.resource
    assert proposal.actions == ["invoke_selected_resource", "record_bounded_evidence"]
    assert {:ok, different} = Config.parse(bytes <> "\n")
    assert {:ok, other} = Acceptance.propose(different)
    refute proposal.config_digest == other.config_digest
  end

  test "strict schema rejects missing, nil, unknown and invalid identities and bounds" do
    invalid = [
      Map.put(config(), "provider", "unknown"),
      Map.put(config(), "scenario", "unknown"),
      Map.put(config(), "schema_version", 2),
      Map.put(config(), "source_revision", nil),
      Map.put(config(), "retain_until", "2000-01-01T00:00:00Z"),
      Map.put(config(), "content", "all"),
      Map.put(config(), "resource", %{"reference" => nil}),
      Map.put(config(), "secret", "forbidden"),
      Map.delete(config(), "inputs")
    ]

    for data <- invalid do
      assert {:error, _} = Config.parse(Jason.encode!(data))
    end

    assert {:error, _} = Config.parse("not json")
  end

  test "each complete bound rejects nonpositive and noninteger values" do
    valid = config()
    assert {:ok, _} = Config.parse(Jason.encode!(valid))

    for field <- ~w(calls records bytes timeout_ms), value <- [0, -1, 1.5, nil, "1"] do
      invalid = put_in(valid, ["bounds", field], value)

      assert {:error, :invalid_bounds} = Config.parse(Jason.encode!(invalid)),
             "accepted #{field}=#{inspect(value)} with all other bounds valid"
    end
  end

  test "bounds require the exact field set independently of their values" do
    valid = config()

    for field <- ~w(calls records bytes timeout_ms) do
      invalid = update_in(valid, ["bounds"], &Map.delete(&1, field))
      assert {:error, :invalid_bounds} = Config.parse(Jason.encode!(invalid))
    end

    invalid = put_in(valid, ["bounds", "unknown"], 1)
    assert {:error, :invalid_bounds} = Config.parse(Jason.encode!(invalid))
  end

  test "programmatic mutation cannot bypass config validation" do
    assert {:ok, config} = Config.parse(Jason.encode!(config()))
    assert {:error, :invalid_config} = Acceptance.propose(%{config | provider: :invalid})
    assert {:error, :invalid_config} = Acceptance.propose(%{config | digest: "stale"})
  end

  test "output root refuses symlinks, shared parents and existing directories without mutation" do
    root = Path.join(System.tmp_dir!(), "acceptance-path-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "config.json")
    File.write!(path, Jason.encode!(config()))
    base = ["--provider", "agentcore", "--scenario", "basic", "--config", path]
    out = Path.join(root, "run")
    assert {:ok, _, :proposal, ^out} = Command.prepare(base ++ ["--out", out])
    refute File.exists?(out)
    assert :ok = Command.run(base ++ ["--out", out])
    refute File.exists?(out)
    File.mkdir!(out)
    assert {:error, :output_collision} = Command.prepare(base ++ ["--out", out])
    link = Path.join(root, "linked")
    File.ln_s!(root, link)
    assert {:error, _} = Command.prepare(base ++ ["--out", Path.join(link, "other")])
    File.chmod!(root, 0o755)
    assert {:error, _} = Command.prepare(base ++ ["--out", Path.join(root, "other")])
  end

  test "command rejects duplicate, unknown, mismatched selectors and stale digests before output" do
    root = Path.join(System.tmp_dir!(), "acceptance-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "config.json")
    File.write!(path, Jason.encode!(config()))
    base = ["--provider", "agentcore", "--scenario", "basic", "--config", path]

    for extra <- [
          ["--provider", "agentcore"],
          ["--typo", "yes"],
          ["--execute", "stale", "--approval-ref", "approved"]
        ] do
      assert {:error, _} = Command.prepare(base ++ extra)
    end

    assert {:error, :digest_mismatch} =
             Command.prepare(base ++ ["--execute", "stale", "--approval-ref", "approved"])

    assert {:error, _} = Command.prepare(List.replace_at(base, 1, "claude-managed-agents"))
    assert {:error, _} = Command.prepare(base ++ ["--out", path])
    assert {:ok, proposal, :proposal, nil} = Command.prepare(base)

    assert {:error, :output_required} =
             Command.prepare(
               base ++ ["--execute", proposal.config_digest, "--approval-ref", "approved"]
             )

    assert File.read!(path) == Jason.encode!(config())
  end
end
