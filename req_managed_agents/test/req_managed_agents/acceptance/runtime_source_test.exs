defmodule ReqManagedAgents.Acceptance.RuntimeSourceTest do
  use ExUnit.Case, async: false

  @package Path.expand("../../..", __DIR__)
  @root Path.dirname(@package)
  @target "Elixir.ReqManagedAgents.Providers.ClaudeManagedAgents.Acceptance.beam"

  @tag timeout: 120_000
  test "source attestation binds normal compiled inputs, module origin and loaded BEAM bytes" do
    scratch =
      Path.join(System.tmp_dir!(), "acceptance-runtime-#{System.unique_integer([:positive])}")

    File.mkdir!(scratch)
    File.chmod!(scratch, 0o700)
    on_exit(fn -> File.rm_rf!(scratch) end)
    fixture = Path.join(scratch, "checkout")
    File.mkdir!(fixture)
    copy_source(fixture)
    git(fixture, ["init", "--quiet"])
    original = commit(fixture)
    build = Path.join(scratch, "build")
    copy_dependencies(build)
    env = environment(scratch, build)

    {output, status} =
      System.cmd(System.find_executable("mix"), ["compile", "--warnings-as-errors"],
        cd: Path.join(fixture, "req_managed_agents"),
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, output
    script = Path.join(scratch, "runtime.exs")
    File.write!(script, script())
    assert probe(fixture, build, env, script, original, "fresh")["attested"]
    ebin = Path.join(build, "lib/req_managed_agents/ebin")
    old_dir = Path.join(scratch, "old-ebin")
    File.mkdir!(old_dir)
    old_beam = Path.join(old_dir, @target)
    File.cp!(Path.join(ebin, @target), old_beam)

    cma =
      Path.join(
        fixture,
        "req_managed_agents/lib/req_managed_agents/providers/claude_managed_agents/acceptance.ex"
      )

    File.write!(
      cma,
      String.replace_suffix(
        File.read!(cma),
        "end\n",
        "  @doc false\n  def acceptance_runtime_fixture_revision, do: :new\nend\n"
      )
    )

    config = Path.join(fixture, "req_managed_agents/lib/req_managed_agents/acceptance/config.ex")
    before = File.read!(config)
    File.write!(config, before <> "\n# synthetic changed compile input\n")
    changed = commit(fixture)
    stale = probe(fixture, build, env, script, changed, "fresh")
    assert stale["disk_verified"]
    refute stale["attested"], "old application build accepted newly committed source"
    assert stale["api_refused"]
    assert stale["native_requests"] == 0

    {output, status} =
      System.cmd(System.find_executable("mix"), ["compile", "--warnings-as-errors"],
        cd: Path.join(fixture, "req_managed_agents"),
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert probe(fixture, build, env, script, changed, "fresh")["attested"]

    config_file = Path.join(fixture, "req_managed_agents/config/config.exs")
    File.write!(config_file, File.read!(config_file) <> "\n# synthetic changed configuration\n")
    config_changed = commit(fixture)
    stale_config = probe(fixture, build, env, script, config_changed, "fresh")
    assert stale_config["disk_verified"]
    refute stale_config["attested"]
    assert stale_config["api_refused"]
    assert stale_config["native_requests"] == 0

    {output, status} =
      System.cmd(System.find_executable("mix"), ["compile", "--warnings-as-errors"],
        cd: Path.join(fixture, "req_managed_agents"),
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert probe(fixture, build, env, script, config_changed, "fresh")["attested"]

    added = Path.join(fixture, "req_managed_agents/lib/acceptance_added_fixture.ex")
    File.write!(added, "defmodule AcceptanceAddedFixture do\nend\n")
    extra = commit(fixture)
    result = probe(fixture, build, env, script, extra, "fresh")
    assert result["disk_verified"]
    refute result["attested"]
    File.rm!(added)
    File.rm!(config)
    missing = commit(fixture)
    result = probe(fixture, build, env, script, missing, "fresh")
    assert result["disk_verified"]
    refute result["attested"]
    File.write!(config, before <> "\n# synthetic changed compile input\n")
    restored = commit(fixture)
    assert probe(fixture, build, env, script, restored, "fresh")["attested"]

    target = Path.join(ebin, @target)
    fresh = Path.join(scratch, "fresh.beam")
    File.cp!(target, fresh)
    refute File.read!(old_beam) == File.read!(fresh)

    for mode <- ["foreign", "loaded_old_new_disk"] do
      if mode == "loaded_old_new_disk", do: File.cp!(old_beam, target)
      result = probe(fixture, build, env, script, restored, mode, [old_beam, fresh])
      assert result["disk_verified"]
      refute result["attested"], mode
      assert result["api_refused"], mode
      assert result["native_requests"] == 0, mode
      File.cp!(fresh, target)
    end

    source_ebin = Path.join(scratch, "foreign-source")
    File.mkdir!(source_ebin)
    source_beam = Path.join(source_ebin, "Elixir.ReqManagedAgents.Acceptance.Source.beam")
    File.cp!(Path.join(ebin, "Elixir.ReqManagedAgents.Acceptance.Source.beam"), source_beam)
    result = probe(fixture, build, env, script, restored, "foreign_source", [source_beam])
    assert result["disk_verified"]
    refute result["attested"]
    assert result["api_refused"]
    assert result["native_requests"] == 0
    assert probe(fixture, build, env, script, restored, "fresh")["attested"]

    hidden = "req_managed_agents/test/support/qa_untracked_probe.ex"
    exclude = Path.join(fixture, ".git/info/exclude")
    File.write!(exclude, File.read!(exclude) <> "\n/" <> hidden <> "\n")

    File.write!(
      Path.join(fixture, hidden),
      "defmodule AcceptanceUntrackedFixture do\n  def loaded?, do: true\nend\n"
    )

    assert git(fixture, ["status", "--porcelain"]) == ""
    refute git(fixture, ["ls-tree", "-r", "--full-tree", "--name-only", restored]) =~ hidden

    {output, status} =
      System.cmd(System.find_executable("mix"), ["compile", "--warnings-as-errors"],
        cd: Path.join(fixture, "req_managed_agents"),
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, output
    ignored = probe(fixture, build, env, script, restored, "ignored_support")
    assert ignored["helper_loaded"]

    refute ignored["attested"],
           "normally compiled ignored support input was accepted as immutable"

    assert ignored["api_refused"]
    assert ignored["native_requests"] == 0
  end

  defp copy_source(fixture) do
    {revision, 0} =
      if File.dir?(Path.join(@root, ".jj")),
        do:
          System.cmd("jj", [
            "--ignore-working-copy",
            "-R",
            @root,
            "log",
            "-r",
            "@",
            "--no-graph",
            "-T",
            "if(empty, parents.map(|c| c.commit_id()).join(\" \"), commit_id)"
          ]),
        else: System.cmd("git", ["-C", @root, "rev-parse", "HEAD"])

    {listing, 0} =
      System.cmd("git", [
        "-C",
        @root,
        "ls-tree",
        "-r",
        "--full-tree",
        "--name-only",
        String.trim(revision)
      ])

    for path <- String.split(listing, "\n", trim: true) do
      source = Path.join(@root, path)

      if File.regular?(source) do
        destination = Path.join(fixture, path)
        File.mkdir_p!(Path.dirname(destination))
        File.cp!(source, destination)
      end
    end
  end

  defp copy_dependencies(build) do
    source = Mix.Project.build_path() |> Path.join("lib")

    for path <- Path.wildcard(Path.join(source, "*")),
        Path.basename(path) != "req_managed_agents" do
      destination = Path.join([build, "lib", Path.basename(path)])
      File.mkdir_p!(Path.dirname(destination))
      File.cp_r!(path, destination)
    end
  end

  defp probe(fixture, build, env, script, revision, mode, extra \\ []) do
    ebin = Path.join(build, "lib/req_managed_agents/ebin")
    paths = beam_paths() ++ ["-pa", ebin]

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        paths ++ [script, fixture, revision, mode | extra],
        cd: Path.join(fixture, "req_managed_agents"),
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, output
    [json] = Regex.run(~r/RUNTIME_SUMMARY=(.*)/, output, capture: :all_but_first)
    Jason.decode!(json)
  end

  defp beam_paths, do: Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

  defp commit(root) do
    git(root, ["add", "."])
    git(root, ["commit", "--quiet", "--allow-empty", "-m", "synthetic fixture"])
    git(root, ["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git(root, args) do
    {output, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "core.hooksPath=/dev/null",
          "-c",
          "commit.gpgsign=false",
          "-c",
          "user.name=Acceptance",
          "-c",
          "user.email=acceptance@example.invalid",
          "-C",
          root | args
        ],
        stderr_to_stdout: true,
        env: [{"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}]
      )

    output
  end

  defp environment(scratch, build) do
    values =
      System.get_env()
      |> Map.take(~w(PATH HOME MIX_HOME HEX_HOME MIX_DEPS_PATH REBAR_CACHE_DIR XDG_CACHE_HOME))

    values =
      Map.merge(values, %{
        "MIX_BUILD_PATH" => build,
        "MIX_DEPS_PATH" => Path.expand(Mix.Project.deps_path(), @package),
        "MIX_ENV" => "test",
        "TMPDIR" => scratch,
        "ERL_FLAGS" => "+S 4:4",
        "AWS_CONFIG_FILE" => "/dev/null",
        "AWS_SHARED_CREDENTIALS_FILE" => "/dev/null",
        "AWS_EC2_METADATA_DISABLED" => "true",
        "ANTHROPIC_API_KEY" => "invented"
      })

    Enum.map(System.get_env(), fn {key, _} -> {key, nil} end) ++ Map.to_list(values)
  end

  defp script do
    ~S'''
    Mix.start()
    [root, revision, mode | extra] = System.argv()
    Mix.Project.in_project(:req_managed_agents, Path.join(root, "req_managed_agents"), fn _ ->
      module = ReqManagedAgents.Providers.ClaudeManagedAgents.Acceptance
      case mode do
        mode when mode in ["foreign", "foreign_source"] -> Code.prepend_path(Path.dirname(hd(extra)))
        "loaded_old_new_disk" ->
          Code.ensure_loaded!(module)
          File.cp!(Enum.at(extra, 1), Path.join(Mix.Project.compile_path(), Atom.to_string(module) <> ".beam"))
        _ -> :ok
      end
      Process.register(self(), :runtime_test_probe)
      Req.default_options(adapter: ReqManagedAgents.Test.AcceptanceAdapter,
        finch_private: %{acceptance_adapter: fn request ->
          send(Process.whereis(:runtime_test_probe), :native_request)
          {request, Req.Response.new(status: 503, body: %{})}
        end})
      helper_loaded = mode == "ignored_support" and Code.ensure_loaded?(AcceptanceUntrackedFixture) and apply(AcceptanceUntrackedFixture, :loaded?, [])
      source = ReqManagedAgents.Acceptance.Source
      disk = match?({:ok, _}, source.verify(root, revision))
      attested = match?({:ok, _}, source.attest(revision))
      data = %{"schema_version" => 1, "provider" => "claude-managed-agents", "scenario" => "basic",
        "resource" => %{"reference" => "synthetic", "environment_id" => "synthetic"},
        "source_revision" => revision, "retain_until" => "2099-01-01T00:00:00Z", "content" => "drop",
        "bounds" => %{"calls" => 1, "records" => 100, "bytes" => 100000, "timeout_ms" => 100},
        "inputs" => %{"prompt" => "Synthetic", "max_list_cost_cents" => 1, "history_pages" => 1}}
      {:ok, config} = ReqManagedAgents.Acceptance.Config.parse(Jason.encode!(data))
      api_refused =
        if attested, do: false, else: ReqManagedAgents.Acceptance.run(config, out: Path.join(System.tmp_dir!(), "out-#{System.unique_integer([:positive])}"), execute: config.digest, approval_ref: "synthetic") == {:error, :source_mismatch}
      count = fn count, n -> receive do :native_request -> count.(count, n + 1) after 0 -> n end end
      IO.puts("RUNTIME_SUMMARY=" <> Jason.encode!(%{disk_verified: disk, attested: attested, api_refused: api_refused, native_requests: count.(count, 0), helper_loaded: helper_loaded}))
    end)
    '''
  end
end
