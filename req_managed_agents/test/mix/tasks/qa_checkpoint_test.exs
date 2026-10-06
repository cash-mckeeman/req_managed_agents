defmodule Mix.Tasks.ReqManagedAgents.QaCheckpointTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.ReqManagedAgents.QaCheckpoint

  test "the baseline directory is required, never derived from the cwd" do
    assert_raise Mix.Error, ~r/--baseline-dir/, fn -> QaCheckpoint.baseline_dir!([]) end
    assert QaCheckpoint.baseline_dir!(baseline_dir: "/tmp/qa-base") == "/tmp/qa-base"

    # run/1 asks for it before its first jj call, so this never creates a workspace.
    assert_raise Mix.Error, ~r/--baseline-dir/, fn -> QaCheckpoint.run([]) end
  end

  @tag :tmp_dir
  test "the capture runs in the package directory of a monorepo baseline", %{tmp_dir: tmp} do
    File.mkdir_p!(Path.join(tmp, "req_managed_agents"))
    File.write!(Path.join([tmp, "req_managed_agents", "mix.exs"]), "")
    assert QaCheckpoint.capture_dir(tmp) == Path.join(tmp, "req_managed_agents")
  end

  @tag :tmp_dir
  test "a single-package baseline is captured at its root", %{tmp_dir: tmp} do
    assert QaCheckpoint.capture_dir(tmp) == tmp
  end
end
