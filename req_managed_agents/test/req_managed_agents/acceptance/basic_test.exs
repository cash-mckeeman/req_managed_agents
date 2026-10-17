defmodule ReqManagedAgents.Acceptance.BasicTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Acceptance
  alias ReqManagedAgents.Acceptance.{Config, Context, Source}
  alias ReqManagedAgents.Evidence.{Artifact, Options, Recorder}
  alias ReqManagedAgents.Providers.BedrockAgentCore.Acceptance, as: AgentCore

  test "actual AgentCore Session captures native completion and stops at the first turn" do
    owner = self()

    events = [
      %{"messageStart" => %{"role" => "assistant"}},
      %{"messageStop" => %{"stopReason" => "end_turn"}}
    ]

    context =
      context(fn invocation ->
        send(owner, {:invocation, invocation})
        {:ok, events}
      end)

    assert {:ok, observations} = AgentCore.run(context)
    assert_receive {:invocation, %{max_iterations: 1}}
    refute_receive {:invocation, _}
    assert Enum.any?(observations, &(&1.name == "local_first_turn_halt"))

    assert Enum.map(AgentCore.assess(context, observations), & &1.outcome) == [
             :passed,
             :passed,
             :passed
           ]

    assert {:ok, capture} = Recorder.snapshot(context.recorder)
    assert Enum.any?(capture.records, &(&1.kind == :native))
    assert {:ok, artifact} = Artifact.write(capture, context.root)
    assert artifact.relative_path == "evidence.json"
    assert {:error, _} = Artifact.write(capture, context.root)
  end

  test "a requires-action first turn never causes another native invocation" do
    owner = self()

    context =
      context(fn _ ->
        send(owner, :invoked)
        {:ok, [%{"messageStop" => %{"stopReason" => "tool_use"}}]}
      end)

    assert {:ok, observations} = AgentCore.run(context)
    assert_receive :invoked
    refute_receive :invoked
    assertions = AgentCore.assess(context, observations)
    assert Enum.find(assertions, &(&1.name == "native_completion")).outcome == :inconclusive
  end

  test "transport failure makes one call and preserves bounded local failure evidence" do
    owner = self()

    context =
      context(fn _ ->
        send(owner, :invoked)
        {:error, :invented_failure}
      end)

    assert {:error, :execution_failed, observations} = AgentCore.run(context)
    assert_receive :invoked
    refute_receive :invoked
    assert Enum.any?(AgentCore.assess(context, observations), &(&1.outcome == :failed))
    assert {:ok, capture} = Recorder.snapshot(context.recorder)
    assert Enum.any?(capture.records, &(&1.kind == :local))
  end

  defp context(invoke) do
    data = %{
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

    {:ok, config} = Config.parse(Jason.encode!(data))
    {:ok, proposal} = Acceptance.propose(config)
    {:ok, options} = Options.new(content: :retain, max_bytes: 100_000, timeout_ms: 1000)
    recorder = start_supervised!({Recorder, options})
    root = Path.join(System.tmp_dir!(), "basic-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    source = %Source{
      revision: config.source_revision,
      tree: String.duplicate("b", 40),
      root: root
    }

    {:ok, context} = Context.new(config, proposal, source, recorder, root, invoke_fun: invoke)
    context
  end
end
