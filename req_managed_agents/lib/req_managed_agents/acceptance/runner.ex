defmodule ReqManagedAgents.Acceptance.Runner do
  @moduledoc "Provider execution and artifact finalization after the command's preflight gates."
  alias ReqManagedAgents.Acceptance.{
    Basic,
    Cleanup,
    Consumption,
    Context,
    Coverage,
    Observation,
    Output,
    Report
  }

  alias ReqManagedAgents.Evidence.{Artifact, Capture, Recorder}
  alias ReqManagedAgents.Providers.BedrockAgentCore.Acceptance, as: AgentCore
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Acceptance, as: ClaudeManagedAgents

  @doc "Run an already validated, source-attested acceptance context; callers own the recorder lifecycle."
  @spec run(Context.t()) :: {:ok, Report.t()} | {:error, Report.t()}
  def run(%Context{} = context) do
    implementation = scenario(context.config.provider)
    observations = run_scenario(implementation, context)
    assertions = implementation.assess(context, observations)

    capture =
      case Basic.capture(context, observations) do
        {:ok, capture} -> capture
        _ -> nil
      end

    {:ok, coverage} = Coverage.new(context.config, capture, observations)
    {:ok, consumption} = Consumption.new(capture, 0)
    {:ok, cleanup} = Cleanup.from_observations(context.config, capture, observations)

    {:ok, report} =
      Report.new(%{
        context: context,
        assertions: assertions,
        coverage: coverage,
        consumed: consumption,
        cleanup: cleanup,
        artifacts: []
      })

    report = finalize(context, observations, report)

    case Output.report(report, context.root) do
      :ok -> if report.outcome == :passed, do: {:ok, report}, else: {:error, report}
      _ -> {:error, failed(report)}
    end
  end

  defp run_scenario(implementation, context) do
    case implementation.run(context) do
      {:ok, observations} -> observations
      {:error, _, observations} -> observations
    end
  rescue
    _ -> failure(context)
  catch
    _, _ -> failure(context)
  end

  defp failure(context) do
    provider =
      if context.config.provider == :agentcore,
        do: ReqManagedAgents.Providers.BedrockAgentCore,
        else: ReqManagedAgents.Providers.ClaudeManagedAgents

    evidence = Recorder.begin(context.recorder, provider)
    Recorder.observe(evidence, :invocation_end, result: :error, error_code: "callback_failed")
    {:ok, observation} = Observation.new("callback_failed", :failed, [])
    [observation]
  end

  defp finalize(context, observations, report) do
    with {:ok, capture} <- Basic.capture(context, observations),
         {:ok, capture} <-
           Capture.new(capture,
             content: context.config.content,
             max_records: context.config.bounds.records,
             max_bytes: context.config.bounds.bytes
           ),
         {:ok, reference} <- Artifact.write(capture, context.root),
         {:ok, %{size: bytes}} <- File.stat(Path.join(context.root, reference.relative_path)),
         {:ok, coverage} <- Coverage.new(context.config, capture, observations),
         {:ok, consumed} <- Consumption.new(capture, bytes),
         {:ok, cleanup} <- Cleanup.from_observations(context.config, capture, observations) do
      refs = MapSet.new(capture.records, &(&1.source_id <> ":" <> &1.id))

      valid =
        Enum.all?(report.assertions, fn assertion ->
          Enum.all?(assertion.evidence, &MapSet.member?(refs, &1))
        end)

      updated = %{
        report
        | artifacts: [reference],
          coverage: coverage,
          consumed: consumed,
          cleanup: cleanup
      }

      if valid, do: updated, else: failed(updated)
    else
      _ -> failed(report)
    end
  end

  defp failed(report) do
    assertions =
      Enum.map(report.assertions, fn
        %{name: "bounded_capture"} = assertion -> %{assertion | outcome: :failed}
        assertion -> assertion
      end)

    %{report | outcome: :failed, assertions: assertions}
  end

  defp scenario(:agentcore), do: AgentCore
  defp scenario(:claude_managed_agents), do: ClaudeManagedAgents
end
