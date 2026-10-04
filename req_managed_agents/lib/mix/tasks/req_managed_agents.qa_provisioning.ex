defmodule Mix.Tasks.ReqManagedAgents.QaProvisioning do
  @shortdoc "Smoke-test the provision → run → teardown lifecycle for both providers"

  @moduledoc """
  Provisioning lifecycle smoke — a runnable, deterministic proof that the full provider-agnostic
  lifecycle works cohesively for BOTH providers:

      provision(spec) → Session.run(provider, handle) → teardown(provider, handle)

  It runs `qa/provisioning_smoke_test.exs` (via `mix test`, so Bypass works), then reports each
  provider's lifecycle. Bedrock runs entirely on injected seams; Claude runs against a Bypass
  control plane + SSE stub. No live AWS/Anthropic. Exits non-zero if any lifecycle is unhealthy.

      mix req_managed_agents.qa_provisioning

  A lifecycle is healthy when: the resource was provisioned (a durable handle came back), a turn
  ran to `end_turn`, and teardown returned `:ok`.
  """
  use Mix.Task

  @capture "qa/provisioning_smoke_test.exs"

  @impl true
  def run(_argv) do
    out = Path.join(System.tmp_dir!(), "qa_provisioning.json")
    File.rm(out)

    {log, status} =
      System.cmd("mix", ["test", @capture], env: [{"QA_OUT", out}], stderr_to_stdout: true)

    if status != 0 or not File.exists?(out) do
      IO.write(log)
      Mix.raise("provisioning smoke failed (the lifecycle test did not complete)")
    end

    out |> File.read!() |> Jason.decode!() |> Map.fetch!("providers") |> report()
  end

  defp report(providers) do
    say("PROVISION → RUN → TEARDOWN lifecycle smoke")
    say(String.duplicate("─", 66))

    healthy =
      Enum.map(providers, fn p ->
        ran? = p["ran_terminal"] == "end_turn"

        # A healthy run also surfaces non-zero token usage — a wrong usage wire-shape shows up here.
        usage? = (p["usage_input"] || 0) > 0 and (p["usage_output"] || 0) > 0
        ok? = p["provisioned"] and ran? and p["teardown_ok"] and usage?
        say(row(p, ran?, usage?, ok?))
        ok?
      end)

    say("")

    if Enum.all?(healthy) do
      say("RESULT: PASS — #{length(healthy)}/#{length(healthy)} provider lifecycles healthy. ∎")
    else
      say("RESULT: FAIL — a provider lifecycle is broken (see ✗ above).")
      exit({:shutdown, 1})
    end
  end

  defp row(p, ran?, usage?, ok?) do
    provider = String.pad_trailing(p["provider"], 9)
    tokens = "in=#{p["usage_input"] || 0} out=#{p["usage_output"] || 0}"

    "#{provider}  provision #{chk(p["provisioned"])}  run #{chk(ran?)} (#{p["ran_terminal"]})  usage #{chk(usage?)} (#{tokens})  teardown #{chk(p["teardown_ok"])}   #{if ok?, do: "PASS", else: "FAIL"}"
  end

  defp chk(true), do: "✓"
  defp chk(_), do: "✗"

  defp say(msg), do: Mix.shell().info(msg)
end
