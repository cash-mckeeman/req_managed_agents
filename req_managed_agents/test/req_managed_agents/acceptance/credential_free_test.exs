defmodule ReqManagedAgents.Acceptance.CredentialFreeTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Rma.Acceptance, as: Command
  alias ReqManagedAgents.AWS.SigV4
  alias ReqManagedAgents.Config

  @targets [
    {Req, :request, 1},
    {Req, :request, 2},
    {Config, :resolve, 4},
    {Config, :resolve!, 3},
    {SigV4, :from_env, 1}
  ]

  test "actual command proposals and refusals never resolve credentials or issue requests" do
    for {module, _, _} = target <- @targets do
      assert {:module, ^module} = Code.ensure_loaded(module)
      assert :erlang.trace_pattern(target, true, [:local]) > 0
    end

    try do
      controls =
        traced(fn ->
          assert {:ok, %{status: 200}} = Req.request(url: "http://example.test", plug: &respond/1)

          assert {:ok, %{status: 200}} =
                   Req.request(Req.new(url: "http://example.test"), plug: &respond/1)

          assert nil == Config.resolve([], :acceptance_invented_key, nil, nil)

          assert "invented" ==
                   Config.resolve!(
                     [acceptance_invented_key: "invented"],
                     :acceptance_invented_key,
                     nil
                   )

          assert %{access_key_id: "invented"} =
                   SigV4.from_env(
                     aws_access_key_id: "invented",
                     aws_secret_access_key: "invented",
                     aws_region: "us-east-1"
                   )
        end)

      for target <- @targets, do: assert(Map.get(controls, target, 0) > 0)

      root =
        Path.join(System.tmp_dir!(), "acceptance-trace-#{System.unique_integer([:positive])}")

      File.mkdir!(root)
      File.chmod!(root, 0o700)
      on_exit(fn -> File.rm_rf!(root) end)
      path = Path.join(root, "config.json")

      bytes =
        Jason.encode!(%{
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
          "bounds" => %{"calls" => 1, "records" => 100, "bytes" => 1000, "timeout_ms" => 1000},
          "inputs" => %{
            "prompt" => "Say hello",
            "model" => nil,
            "max_tokens" => 16,
            "timeout_seconds" => 1
          }
        })

      File.write!(path, bytes)
      args = ["--provider", "agentcore", "--scenario", "basic", "--config", path]

      counts =
        traced(fn ->
          assert :ok = Command.run(args)
          assert_raise Mix.Error, fn -> Command.run(List.replace_at(args, 1, "typo")) end

          assert_raise Mix.Error, fn ->
            Command.run(args ++ ["--execute", "stale", "--approval-ref", "approved"])
          end

          assert_raise Mix.Error, fn -> Command.run(args ++ ["--out", path]) end
        end)

      assert counts == %{}
    after
      for target <- @targets, do: :erlang.trace_pattern(target, false, [:local])
    end
  end

  test "a dead traced subject preserves the original assertion failure" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert_raise ExUnit.AssertionError, ~r/traced subject failed/, fn ->
        traced(fn -> raise "synthetic subject failure" end)
      end
    end)
  end

  defp respond(conn), do: Plug.Conn.send_resp(conn, 200, "{}")

  defp traced(fun) do
    parent = self()

    {subject, monitor} =
      spawn_monitor(fn ->
        receive do
          :start ->
            fun.()
            send(parent, {:finished, self()})
            receive do: (:stop -> :ok)
        end
      end)

    assert :erlang.trace(subject, true, [:call, :arity]) == 1
    send(subject, :start)

    try do
      collect(subject, monitor, %{}, nil)
    after
      stop_subject(subject, monitor)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp stop_subject(subject, monitor) do
    if Process.alive?(subject) do
      try do
        :erlang.trace(subject, false, [:call])
      rescue
        ArgumentError -> :ok
      after
        Process.exit(subject, :kill)
      end

      receive do
        {:DOWN, ^monitor, :process, ^subject, _} -> :ok
      after
        1000 -> flunk("owned traced subject did not stop")
      end
    end
  end

  defp collect(subject, monitor, counts, barrier) do
    receive do
      {:trace, ^subject, :call, target} ->
        collect(subject, monitor, Map.update(counts, target, 1, &(&1 + 1)), barrier)

      {:finished, ^subject} ->
        collect(subject, monitor, counts, :erlang.trace_delivered(subject))

      {:trace_delivered, ^subject, ^barrier} when not is_nil(barrier) ->
        counts

      {:DOWN, ^monitor, :process, ^subject, reason} ->
        flunk("traced subject failed: #{inspect(reason)}")
    after
      10_000 -> flunk("trace delivery timed out")
    end
  end
end
