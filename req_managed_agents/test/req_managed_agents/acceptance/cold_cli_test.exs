defmodule ReqManagedAgents.Acceptance.ColdCliTest do
  use ExUnit.Case, async: false

  @package Path.expand("../../..", __DIR__)
  @root Path.dirname(@package)

  test "cold command starts its application tree only after valid execution preflight" do
    root = Path.join(System.tmp_dir!(), "acceptance-cold-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    script = Path.join(root, "cold.exs")
    File.write!(script, script())
    revision = revision()

    for mode <- [:proposal, :wrong_digest, :wrong_source, :execute] do
      config = config(if mode == :wrong_source, do: String.duplicate("0", 40), else: revision)
      bytes = Jason.encode!(config)
      path = Path.join(root, "#{mode}.json")
      File.write!(path, bytes)
      digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      digest = if mode == :wrong_digest, do: String.duplicate("0", 64), else: digest
      out = Path.join(root, "#{mode}-out")
      args = ["--provider", "claude-managed-agents", "--scenario", "basic", "--config", path]

      args =
        if mode == :proposal,
          do: args,
          else: args ++ ["--out", out, "--execute", digest, "--approval-ref", "synthetic-test"]

      beam_paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

      {output, status} =
        System.cmd(System.find_executable("elixir"), beam_paths ++ [script | args],
          cd: @package,
          env: environment(root),
          stderr_to_stdout: true
        )

      assert status == 0, output
      [summary] = Regex.run(~r/COLD_SUMMARY=(.*)/, output, capture: :all_but_first)
      result = Jason.decode!(summary)

      if mode == :execute do
        assert result["native_requests"] == 1, output
        assert result["native_ready"] == true, output
        assert result["apps_started"] == true, output
      else
        assert result["native_requests"] == 0, output
        assert result["apps_started"] == false, output
        refute File.exists?(out)
      end
    end
  end

  defp revision do
    command =
      if File.dir?(Path.join(@root, ".jj")),
        do:
          {"jj",
           [
             "--ignore-working-copy",
             "-R",
             @root,
             "log",
             "-r",
             "@",
             "--no-graph",
             "-T",
             "if(empty, parents.map(|c| c.commit_id()).join(\" \"), commit_id)"
           ]},
        else: {"git", ["-C", @root, "rev-parse", "HEAD"]}

    {executable, args} = command
    {revision, 0} = System.cmd(executable, args)
    String.trim(revision)
  end

  defp environment(root) do
    preserved =
      System.get_env()
      |> Map.take(
        ~w(PATH HOME MIX_HOME HEX_HOME MIX_DEPS_PATH MIX_BUILD_PATH MIX_ENV REBAR_CACHE_DIR XDG_CACHE_HOME)
      )
      |> Map.merge(%{
        "TMPDIR" => root,
        "ERL_FLAGS" => "+S 4:4",
        "AWS_CONFIG_FILE" => "/dev/null",
        "AWS_SHARED_CREDENTIALS_FILE" => "/dev/null",
        "AWS_EC2_METADATA_DISABLED" => "true",
        "ANTHROPIC_API_KEY" => "invented"
      })

    Enum.map(System.get_env(), fn {key, _} -> {key, nil} end) ++ Map.to_list(preserved)
  end

  defp config(revision) do
    %{
      "schema_version" => 1,
      "provider" => "claude-managed-agents",
      "scenario" => "basic",
      "resource" => %{"reference" => "synthetic-agent", "environment_id" => "synthetic-env"},
      "source_revision" => revision,
      "retain_until" => "2099-01-01T00:00:00Z",
      "content" => "drop",
      "bounds" => %{"calls" => 1, "records" => 100, "bytes" => 100_000, "timeout_ms" => 1000},
      "inputs" => %{"prompt" => "Synthetic", "max_list_cost_cents" => 1, "history_pages" => 1}
    }
  end

  defp script do
    ~S'''
    Mix.start()
    Process.register(self(), :acceptance_cold_probe)
    ready = fn ->
      Enum.all?([:req, :finch, :req_managed_agents], &List.keymember?(Application.started_applications(), &1, 0))
    end
    Req.default_options(adapter: ReqManagedAgents.Test.AcceptanceAdapter,
      finch_private: %{acceptance_adapter: fn request ->
        pools = is_pid(Process.whereis(Req.Finch)) and is_pid(Process.whereis(ReqManagedAgents.StreamFinch))
        send(Process.whereis(:acceptance_cold_probe), {:cold_native, ready.() and pools})
        {request, Req.Response.new(status: 503, body: %{})}
      end})
    try do
      Mix.CLI.main(["rma.acceptance" | System.argv()])
    rescue
      _ -> :ok
    catch
      :exit, {:shutdown, 1} -> :ok
    end
    collect = fn collect, acc ->
      receive do
        {:cold_native, ready} -> collect.(collect, [ready | acc])
      after
        0 -> acc
      end
    end
    requests = collect.(collect, [])
    IO.puts("COLD_SUMMARY=" <> Jason.encode!(%{native_requests: length(requests), native_ready: requests != [] and Enum.all?(requests), apps_started: ready.()}))
    '''
  end
end
