defmodule ReqManagedAgents.AgentCore.SmokeTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.ReqManagedAgents.AgentCore.Smoke

  @moduledoc """
  Guards the AgentCore end-to-end smoke under `mix test` / CI so the composed
  stack (SigV4 → EventStream → Converse parse → tool → resume) is verified on
  every build, not only on explicit smoke runs.
  """

  test "run_smoke/0 returns {:ok, results} with every stage passing" do
    assert {:ok, results} = Smoke.run_smoke()

    failures = Enum.filter(results, fn {_, status, _} -> status == :fail end)

    assert failures == [],
           "Failing stages:\n" <>
             Enum.map_join(failures, "\n", fn {name, _, detail} ->
               "  [FAIL] #{name} — #{detail}"
             end)
  end
end
