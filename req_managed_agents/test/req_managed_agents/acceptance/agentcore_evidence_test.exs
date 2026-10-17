defmodule ReqManagedAgents.Acceptance.AgentCoreEvidenceTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Acceptance
  alias ReqManagedAgents.Acceptance.{Config, Context, Output, Proposal, Runner, Source}
  alias ReqManagedAgents.CloudWatch.Client, as: LogsClient
  alias ReqManagedAgents.CloudWatch.Query
  alias ReqManagedAgents.EventStreamFrames
  alias ReqManagedAgents.Evidence
  alias ReqManagedAgents.Evidence.{Options, Recorder}
  alias ReqManagedAgents.Providers.BedrockAgentCore.Client

  for mode <- [:recognized, :denied, :empty, :partial, :capped, :unknown] do
    @mode mode
    test "#{mode} stored evidence is distinct from one real inline invocation" do
      {context, state} = context(@mode)
      assert {:ok, proposal} = Acceptance.propose(context.config)

      assert proposal.required_assertions ==
               ~w(native_activity native_completion bounded_capture stored_evidence)

      assert "read_selected_isolated_log_group" in proposal.actions
      assert %Query{} = proposal.selection

      refute Jason.encode!(Proposal.to_wire(proposal)) =~
               "/synthetic/isolated"

      result = Runner.run(context)
      report = elem(result, 1)
      stored = Enum.find(report.assertions, &(&1.name == "stored_evidence"))

      if @mode == :recognized do
        assert {:ok, _} = result
        assert stored.outcome == :passed
        assert stored.evidence != []
        stored_sources = Enum.filter(report.coverage.sources, &(&1.kind == :cloudwatch))
        assert stored_sources != []

        assert Enum.all?(stored.evidence, fn ref ->
                 Enum.any?(stored_sources, &String.starts_with?(ref, &1.source_id <> ":"))
               end)
      else
        assert {:error, _} = result
        assert stored.outcome == :inconclusive
      end

      assert Agent.get(state, & &1.invokes) == 1
      assert length(Agent.get(state, & &1.reads)) == 1
      before = Agent.get(state, & &1.inline)
      assert before != []
      assert Enum.any?(before, &(&1.kind == :native))
      assert [artifact] = report.artifacts
      bytes = File.read!(Path.join(context.root, artifact.relative_path))
      refute bytes =~ "unknown-private-dialect"
      assert {:ok, capture} = Evidence.from_wire(Jason.decode!(bytes))

      assert Enum.take(Enum.map(capture.records, &identity/1), length(before)) ==
               Enum.map(before, &identity/1)

      assert "sessionassociation_not_tracejoin" in report.coverage.limitations
      assert Enum.all?(capture.correlations, &(&1.relation == :same_session))

      assert Enum.all?(
               Enum.filter(capture.records, &(&1.source_id != "native" and &1.kind == :native)),
               &(is_nil(&1.invocation_id) and is_nil(&1.attempt_id))
             )
    end
  end

  test "unisolated or malformed destinations refuse proposal before any transport" do
    for replacement <- [
          %{"isolated_destination" => false},
          %{"log_group" => ""},
          %{"trace_ids" => ["not-a-trace"]},
          %{"from" => "invalid"},
          %{"extra" => true}
        ] do
      data = config()
      cloudwatch = Map.merge(data["inputs"]["cloudwatch"], replacement)

      {:ok, config} =
        Config.parse(Jason.encode!(put_in(data, ["inputs", "cloudwatch"], cloudwatch)))

      assert {:error, _} = Acceptance.propose(config)
    end
  end

  defp identity(record),
    do:
      {record.id, record.source_id, record.native_id, record.ordinal, record.invocation_id,
       record.attempt_id, record.observed_at}

  defp context(mode) do
    data = config()
    {:ok, config} = Config.parse(Jason.encode!(data))
    {:ok, proposal} = Acceptance.propose(config)

    state =
      start_supervised!({Agent, fn -> %{invokes: 0, reads: [], recorder: nil, inline: nil} end})

    native =
      Client.new(
        credentials: %{
          access_key_id: "invented",
          secret_access_key: "invented",
          security_token: nil,
          region: "us-east-1"
        },
        req_options: [
          plug: fn conn ->
            Agent.update(state, &%{&1 | invokes: &1.invokes + 1})

            frames = [
              %{"messageStart" => %{"role" => "assistant"}},
              %{"messageStop" => %{"stopReason" => "end_turn"}}
            ]

            Plug.Conn.send_resp(
              conn,
              200,
              frames
              |> Enum.map(&EventStreamFrames.frame(Jason.encode!(&1)))
              |> IO.iodata_to_binary()
            )
          end
        ]
      )

    {:ok, logs} =
      LogsClient.new(
        region: "us-east-1",
        credentials: %{access_key_id: "invented", secret_access_key: "invented"},
        transport: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          request = Jason.decode!(body)
          assert request["logGroupName"] == "/synthetic/isolated"
          assert request["unmask"] == false
          refute Map.has_key?(request, "filterPattern")
          recorder = Agent.get(state, & &1.recorder)
          {:ok, before} = Recorder.snapshot(recorder)
          Agent.update(state, &%{&1 | reads: &1.reads ++ [request], inline: before.records})
          {status, page} = page(mode)
          Plug.Conn.send_resp(conn, status, Jason.encode!(page))
        end
      )

    {:ok, options} =
      Options.new(
        content: :retain,
        max_records: config.bounds.records,
        max_bytes: config.bounds.bytes,
        timeout_ms: config.bounds.timeout_ms
      )

    recorder = start_supervised!({Recorder, options})
    Agent.update(state, &%{&1 | recorder: recorder})

    parent =
      Path.join(System.tmp_dir!(), "agentcore-evidence-#{System.unique_integer([:positive])}")

    File.mkdir!(parent)
    File.chmod!(parent, 0o700)
    on_exit(fn -> File.rm_rf!(parent) end)
    root = Path.join(parent, "run")
    :ok = Output.create(root)

    source = %Source{
      revision: config.source_revision,
      tree: String.duplicate("b", 40),
      root: parent
    }

    {:ok, context} =
      Context.new(config, proposal, source, recorder, root,
        client: native,
        cloudwatch_client: logs
      )

    {context, state}
  end

  defp page(:recognized), do: {200, %{"events" => [event()]}}
  defp page(:denied), do: {403, %{"message" => "synthetic-denied"}}
  defp page(:empty), do: {200, %{"events" => []}}
  defp page(:partial), do: {200, %{"events" => [event()], "nextToken" => 42}}
  defp page(:capped), do: {200, %{"events" => [event()], "nextToken" => "another-page"}}

  defp page(:unknown),
    do: {200, %{"events" => [%{event() | "message" => "unknown-private-dialect"}]}}

  defp event do
    span = %{
      "traceId" => String.duplicate("a", 32),
      "spanId" => String.duplicate("1", 16),
      "name" => "synthetic operation",
      "startTimeUnixNano" => "100",
      "endTimeUnixNano" => "200",
      "attributes" => [
        %{"key" => "session.id", "value" => %{"stringValue" => String.duplicate("s", 33)}}
      ]
    }

    %{
      "eventId" => "stored-event",
      "logStreamName" => "synthetic",
      "timestamp" => 1_767_225_600_000,
      "ingestionTime" => 1_767_225_601_000,
      "message" =>
        Jason.encode!(%{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => [span]}]}]})
    }
  end

  defp config do
    %{
      "schema_version" => 1,
      "provider" => "agentcore",
      "scenario" => "evidence",
      "resource" => %{
        "reference" => "arn:aws:bedrock-agentcore:us-east-1:000000000000:harness/invented",
        "region" => "us-east-1",
        "runtime_session_id" => String.duplicate("s", 33)
      },
      "source_revision" => String.duplicate("a", 40),
      "retain_until" => "2099-01-01T00:00:00Z",
      "content" => "drop",
      "bounds" => %{"calls" => 1, "records" => 100, "bytes" => 100_000, "timeout_ms" => 1000},
      "inputs" => %{
        "prompt" => "Synthetic hello",
        "model" => nil,
        "max_tokens" => 16,
        "timeout_seconds" => 1,
        "history_pages" => 1,
        "cloudwatch" => %{
          "log_group" => "/synthetic/isolated",
          "from" => "2026-01-01T00:00:00Z",
          "to" => "2026-01-01T00:01:00Z",
          "trace_ids" => [],
          "isolated_destination" => true
        }
      }
    }
  end
end
