defmodule Mix.Tasks.ReqManagedAgents.QaCheckpoint do
  @shortdoc "Prove provider behavior is unchanged between a baseline commit (PR11) and HEAD (PR13)"

  @moduledoc """
  QA-CHECKPOINT — canonical proof that the Provider/Session refactor changed no observable
  behavior of either provider.

  It runs the SAME deterministic capture (`qa/checkpoint_capture_test.exs`) against two states of
  the codebase and diffs the resulting behavior fingerprints:

    * **PR11 (baseline)** — the three old drivers, in a throwaway jj worktree at `--base`.
    * **PR13 (current)** — the unified `Session`, in this worktree.

  The capture drives both providers through the public facade with deterministic transports (the
  Bedrock `invoke_fun` seam + a Bypass SSE stub), so the only variable is the codebase. Per
  scenario it records: result tag, terminal, normalized stop-reason, the tool calls the loop ran,
  final event count, and any error. Those fields must match exactly. One field —
  `stop_reason_raw_kind` — is informational (the documented Claude map→string change) and is
  reported but not failed.

      mix req_managed_agents.qa_checkpoint
      mix req_managed_agents.qa_checkpoint --base main@origin --rebuild

  Options:

    * `--base REV`   baseline revision (default `main@origin`)
    * `--rebuild`    recreate the baseline worktree from scratch
    * `--keep`       leave the baseline worktree in place after running (default; reused next run)
  """
  use Mix.Task

  @capture "qa/checkpoint_capture_test.exs"
  @compared ~w(result terminal stop_reason_type tool_calls n_final_events error)

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [base: :string, rebuild: :boolean, keep: :boolean])

    base = opts[:base] || "main@origin"
    # Sibling worktree under .claude/worktrees/ (this task runs from a worktree there).
    pr11_dir = Path.expand("../qa-checkpoint-pr11", File.cwd!())
    tmp = System.tmp_dir!()
    pr11_out = Path.join(tmp, "qa_pr11.json")
    pr13_out = Path.join(tmp, "qa_pr13.json")

    base_commit = resolve(base)
    head_commit = resolve("@")

    say("QA-CHECKPOINT — provider behavioral equivalence")
    say("  baseline (PR11): #{base} = #{base_commit}")
    say("  current  (PR13): #{head_commit}")
    say("")

    setup_baseline(pr11_dir, base, opts[:rebuild])

    say("→ capturing PR11 fingerprint (#{pr11_dir})")
    capture!(pr11_dir, pr11_out)

    say("→ capturing PR13 fingerprint (this worktree)")
    capture!(File.cwd!(), pr13_out)

    say("")
    report(load(pr11_out), load(pr13_out))
  end

  # ── baseline worktree ────────────────────────────────────────────────────────────────
  defp setup_baseline(dir, base, rebuild) do
    if rebuild && File.dir?(dir) do
      say("→ removing existing baseline worktree (--rebuild)")
      _ = cmd("jj", ["workspace", "forget", Path.basename(dir)])
      File.rm_rf!(dir)
    end

    unless File.dir?(dir) do
      say("→ creating baseline worktree at #{base}")
      {out, 0} = cmd("jj", ["workspace", "add", "--revision", base, dir])
      IO.write(out)
    end

    File.mkdir_p!(Path.join(dir, "qa"))
    File.cp!(@capture, Path.join([dir, "qa", "checkpoint_capture_test.exs"]))

    say("→ fetching baseline deps")
    {_, status} = cmd("mix", ["deps.get"], cd: dir)
    if status != 0, do: Mix.raise("baseline `mix deps.get` failed")
  end

  # ── run the capture, producing a fingerprint JSON ──────────────────────────────────────
  defp capture!(dir, out) do
    File.rm(out)
    {log, status} = cmd("mix", ["test", @capture], cd: dir, env: [{"QA_OUT", out}])

    if status != 0 or not File.exists?(out) do
      IO.write(log)
      Mix.raise("capture failed in #{dir} (exit #{status})")
    end
  end

  # ── verdict (prints; exits 1 on divergence) ────────────────────────────────────────────
  defp report(pr11, pr13) do
    c = compare(pr11, pr13)

    say(String.pad_trailing("SCENARIO", 26) <> "  BEHAVIOR (PR11 = PR13)")
    say(String.duplicate("─", 64))

    Enum.each(c.scenarios, fn s ->
      say(row(s.name, s.fp, s.mismatches == []))

      for {f, xv, yv} <- s.mismatches,
          do: say("    ✗ #{f}: PR11=#{inspect(xv)}  PR13=#{inspect(yv)}")
    end)

    say("")
    say("Compared fields: #{Enum.join(@compared, ", ")}")

    if c.allowlisted != [] do
      say("Allow-listed intentional changes (documented in the spec, not failed):")
      for {name, x, y} <- c.allowlisted, do: say("  #{name}: stop_reason #{x} → #{y}")
    end

    say("")

    if c.pass == c.total do
      say(
        "RESULT: PASS — #{c.pass}/#{c.total} scenarios behaviorally identical across both providers."
      )

      say("The Provider/Session refactor preserved all observable behavior. ∎")
    else
      say("RESULT: FAIL — #{c.total - c.pass}/#{c.total} scenarios diverged. See ✗ rows above.")
      exit({:shutdown, 1})
    end
  end

  @doc """
  Pure comparison of two fingerprint scenario-lists. Returns `%{scenarios:, pass:, total:,
  allowlisted:}`; a scenario passes when its `@compared` fields match exactly. Public so the
  pass/fail gate is unit-tested (a gate that cannot fail proves nothing).
  """
  def compare(pr11, pr13) do
    a = Map.new(pr11, &{&1["scenario"], &1})
    b = Map.new(pr13, &{&1["scenario"], &1})
    names = (Map.keys(a) ++ Map.keys(b)) |> Enum.uniq() |> Enum.sort()

    scenarios =
      Enum.map(names, fn name ->
        %{name: name, fp: b[name] || a[name], mismatches: field_mismatches(a[name], b[name])}
      end)

    %{
      scenarios: scenarios,
      pass: Enum.count(scenarios, &(&1.mismatches == [])),
      total: length(scenarios),
      allowlisted: allowlisted(a, b)
    }
  end

  defp field_mismatches(nil, y), do: [{"presence", nil, y && y["scenario"]}]
  defp field_mismatches(x, nil), do: [{"presence", x["scenario"], nil}]
  defp field_mismatches(x, y), do: for(f <- @compared, x[f] != y[f], do: {f, x[f], y[f]})

  # The allow-listed informational field: reported, never failed.
  defp allowlisted(a, b) do
    for name <- Enum.sort(Map.keys(a)),
        y = b[name],
        x = a[name],
        x["stop_reason_raw_kind"] != y["stop_reason_raw_kind"],
        do: {name, x["stop_reason_raw_kind"], y["stop_reason_raw_kind"]}
  end

  defp row(name, fp, ok?) do
    behavior =
      case fp do
        %{"result" => "error", "error" => e} -> "error #{e}"
        %{"terminal" => t, "tool_calls" => tc} -> "ok #{t} tools=#{inspect(tc)}"
        _ -> "?"
      end

    "#{String.pad_trailing(name, 26)}  #{behavior}  #{if ok?, do: "✓", else: "✗"}"
  end

  # ── helpers ────────────────────────────────────────────────────────────────────────────
  defp resolve(rev) do
    {out, 0} = cmd("jj", ["log", "-r", rev, "--no-graph", "-T", "commit_id.short()"])
    String.trim(out)
  end

  defp load(path), do: path |> File.read!() |> Jason.decode!() |> Map.fetch!("scenarios")

  defp cmd(bin, args, extra \\ []) do
    {out, status} = System.cmd(bin, args, [stderr_to_stdout: true] ++ extra)
    {out, status}
  end

  defp say(msg), do: Mix.shell().info(msg)
end
