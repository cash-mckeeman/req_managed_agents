defmodule ReqManagedAgents.LiveCanaryWorkflowTest do
  # Contract tests over .github/workflows/live-canary.yml — the canary's own
  # operability, which is not covered by any other test in this repo.
  #
  # Two consecutive scheduled runs failed with nothing in the run log that
  # named a cause: no step declared an `id:`, so no step outcome was
  # addressable; the workflow held `contents: read` only, so it could not file
  # an issue even if it had something to say; nothing checked that the AWS and
  # Anthropic credentials existed before spending setup on them; nothing
  # stopped a manual rerun from overlapping the cron and racing it for the same
  # content-addressed harness name; and nothing reclaimed a harness the suite
  # left behind.
  #
  # These tests pin the invariants that keep the next failure readable from the
  # run log alone and stop a failed run from billing indefinitely.
  use ExUnit.Case, async: true

  @workflow_path Path.expand("../../.github/workflows/live-canary.yml", __DIR__)

  # Every value the canary cannot run without. AWS_ROLE_ARN and
  # HARNESS_EXECUTION_ROLE_ARN are repository/environment *vars*;
  # ANTHROPIC_API_KEY is a secret. All three fail opaquely and late when unset.
  @required_credentials ~w(AWS_ROLE_ARN HARNESS_EXECUTION_ROLE_ARN ANTHROPIC_API_KEY)

  setup_all do
    {:ok, workflow} = YamlElixir.read_from_file(@workflow_path)

    job = get_in(workflow, ["jobs", "live"])
    assert is_map(job), "live-canary.yml must define a job named `live`"

    steps = job["steps"]
    assert is_list(steps) and steps != []

    %{workflow: workflow, job: job, steps: steps}
  end

  describe "credential preflight" do
    test "precedes credential assumption and names every required credential", %{steps: steps} do
      preflight_idx = Enum.find_index(steps, &(&1["id"] == "preflight"))
      assert preflight_idx, "the workflow must carry a step with id: preflight"

      aws_idx =
        Enum.find_index(steps, fn step ->
          is_binary(step["uses"]) and step["uses"] =~ "aws-actions/configure-aws-credentials"
        end)

      assert aws_idx, "the workflow must assume the CI role via configure-aws-credentials"

      assert preflight_idx < aws_idx,
             "preflight must run before OIDC assumption, so an unset vars.AWS_ROLE_ARN fails " <>
               "by name instead of as \"Could not load credentials from any providers\""

      preflight = Enum.at(steps, preflight_idx)

      for required <- @required_credentials do
        assert Map.has_key?(preflight["env"] || %{}, required),
               "preflight env must surface #{required} so its absence is checked by name"

        assert preflight["run"] =~ required,
               "the preflight script must check and name #{required}"
      end
    end
  end

  describe "step addressability" do
    test "every step declares an id", %{steps: steps} do
      unidentified = Enum.reject(steps, &is_binary(&1["id"]))
      named = Enum.map(unidentified, &(&1["name"] || &1["uses"]))

      assert unidentified == [],
             "the failure filer reports `toJSON(steps)`, which contains only steps that " <>
               "declare an id — an id-less step is invisible in the filed issue: " <>
               inspect(named)
    end

    test "overriding the default success gate requires a prerequisite guard", %{steps: steps} do
      overriding =
        Enum.filter(steps, fn step ->
          is_binary(step["if"]) and step["if"] =~ ~r/always\(\)|!\s*cancelled\(\)/
        end)

      for step <- overriding do
        assert step["if"] =~ ~r/steps\.\w+\.outcome/,
               "step #{inspect(step["id"])} overrides the success() gate " <>
                 "(#{inspect(step["if"])}) without checking that its prerequisites ran — " <>
                 "on a runner where setup was skipped this is `mix: command not found`, " <>
                 "a red step that explains nothing"
      end
    end
  end

  describe "failure issue filer" do
    setup %{steps: steps} do
      filer =
        Enum.find(steps, fn step ->
          is_binary(step["uses"]) and step["uses"] =~ "actions/github-script" and
            (get_in(step, ["with", "script"]) || "") =~ "issues.create"
        end)

      assert filer, "the workflow must file an issue when the canary fails"
      %{filer: filer, script: get_in(filer, ["with", "script"])}
    end

    test "fires on any job failure, not only on the suite's own", %{filer: filer} do
      assert String.trim(filer["if"] || "") == "failure()",
             "gating the filer on the suite step's outcome silences every failure that " <>
               "happens before the suite runs — which is every failure so far " <>
               "(got: #{inspect(filer["if"])})"
    end

    test "embeds per-step outcomes and links the run", %{script: script} do
      assert script =~ "toJSON(steps)",
             "the filer must embed step outcomes so the first red step is named in the issue"

      assert script =~ "context.runId",
             "the filer must link the failing run"
    end

    test "distinguishes a harness failure from provider drift", %{script: script} do
      assert script =~ "live_suite",
             "the filer must branch on whether the live suite itself failed — otherwise a " <>
               "broken runner is filed as provider drift"

      assert script =~ "HARNESS",
             "the harness-failure shape must say so in the issue title, so a reader does " <>
               "not go hunting for an API change that never happened"
    end
  end

  describe "workflow permissions" do
    test "grants issues: write", %{workflow: workflow} do
      assert get_in(workflow, ["permissions", "issues"]) == "write",
             "the filer calls issues.create; with contents: read only the job token cannot " <>
               "create an issue and the failure is recorded nowhere"
    end
  end

  describe "concurrency" do
    test "a manual rerun cannot overlap the scheduled run", %{workflow: workflow} do
      group = get_in(workflow, ["concurrency", "group"])
      assert is_binary(group) and group != "", "the workflow must declare a concurrency group"

      refute group =~ ~r/github\.(ref|ref_name|sha|run_id|run_number|event_name|head_ref)/,
             "the group must resolve identically for a schedule and a workflow_dispatch of " <>
               "this workflow — keying it on anything that differs between the two events " <>
               "lets a manual rerun provision the same content-addressed harness name the " <>
               "scheduled run is already using, and one run then adopts or deletes the " <>
               "other's harness (got: #{inspect(group)})"

      refute get_in(workflow, ["concurrency", "cancel-in-progress"]) == true,
             "cancelling an in-flight run kills it outside its own cleanup, orphaning the " <>
               "harness it had already created — queue the second run instead"
    end
  end

  describe "job-level guards" do
    test "the job carries a wall-clock timeout", %{job: job} do
      timeout = job["timeout-minutes"]

      assert is_integer(timeout),
             "without timeout-minutes a hung provisioning poll holds the runner for " <>
               "GitHub's 6-hour default with the harness still allocated"

      assert timeout <= 60, "the canary should be bounded well under an hour (got: #{timeout})"
    end

    test "failure uploads the run's diagnostics", %{steps: steps} do
      upload =
        Enum.find(steps, &(is_binary(&1["uses"]) and &1["uses"] =~ "actions/upload-artifact"))

      assert upload, "a failed canary must leave its logs behind as an artifact"

      assert String.trim(upload["if"] || "") =~ "failure()",
             "the upload must fire on failure — that is the run whose logs anyone will want"
    end
  end

  describe "orphaned-harness sweep" do
    setup %{steps: steps} do
      sweep = Enum.find(steps, &(&1["id"] == "sweep"))
      assert sweep, "the workflow must sweep leftover harnesses after the suite"
      %{sweep: sweep}
    end

    test "runs after the suite on every exit path and deletes what it finds", ctx do
      %{sweep: sweep, steps: steps} = ctx

      assert String.trim(sweep["if"] || "") =~ "always()",
             "a leaked harness bills whether the suite passed, failed, or was killed by the " <>
               "job timeout — and the timeout kill is exactly the path that leaks"

      assert sweep["run"] =~ ~r/list[-_]harnesses/,
             "the sweep must list harnesses before deciding what to reclaim"

      assert sweep["run"] =~ ~r/delete[-_]harness/,
             "listing without deleting reports the leak instead of closing it"

      suite_idx = Enum.find_index(steps, &(&1["id"] == "live_suite"))
      sweep_idx = Enum.find_index(steps, &(&1["id"] == "sweep"))

      assert is_integer(suite_idx) and suite_idx < sweep_idx,
             "the sweep must run after the suite whose leftovers it collects"
    end

    test "the glob is not narrowed to the current naming scheme", %{sweep: sweep} do
      assert sweep["run"] =~ "rma_live",
             "the sweep must match the canary's harness-name prefix"

      refute sweep["run"] =~ ~r/rma_live_[a-z]/,
             "harnesses stranded by earlier runs carry an older, truncated name that also " <>
               "begins rma_live; narrowing the prefix to the current scheme strands exactly " <>
               "the orphans this step exists to reclaim"
    end
  end
end
