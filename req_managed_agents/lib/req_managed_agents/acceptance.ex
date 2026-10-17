defmodule ReqManagedAgents.Acceptance do
  @moduledoc "On-demand managed-provider acceptance with explicit source and configuration confirmation."
  alias ReqManagedAgents.Acceptance.{
    Basic,
    Cleanup,
    Config,
    Consumption,
    Context,
    Coverage,
    Observation,
    Output,
    Proposal,
    Report,
    Source
  }

  alias ReqManagedAgents.Evidence.{Artifact, Capture, Options, Recorder}
  alias ReqManagedAgents.Providers.BedrockAgentCore.Acceptance, as: AgentCore
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Acceptance, as: ClaudeManagedAgents

  @doc "Propose only supported, fully validated scenarios without provider activity."
  @spec propose(Config.t()) :: {:ok, Proposal.t()} | {:error, atom()}
  def propose(%Config{} = candidate) do
    with {:ok, config} <- Config.new(candidate), do: scenario(config.provider).propose(config)
  end

  @doc "Execute after exact digest confirmation and actual clean-checkout attestation."
  @spec run(Config.t(), keyword()) :: {:ok, Report.t()} | {:error, Report.t() | atom()}
  def run(%Config{} = config, opts) do
    with {:ok, proposal} <- propose(config),
         :ok <- confirmation(config, opts),
         {:ok, source} <- Source.attest(config.source_revision),
         :ok <- Output.create(opts[:out]),
         {:ok, options} <-
           Options.new(
             max_records: config.bounds.records,
             max_bytes: config.bounds.bytes,
             timeout_ms: config.bounds.timeout_ms,
             content: :retain
           ),
         {:ok, recorder} <- Recorder.start_link(options) do
      try do
        {:ok, context} =
          Context.new(config, proposal, source, recorder, opts[:out], opts[:transport] || [])

        Recorder.context(
          recorder,
          evidence_provider(config.provider),
          config.resource["runtime_session_id"]
        )

        execute(context)
      after
        if Process.alive?(recorder), do: GenServer.stop(recorder)
      end
    end
  end

  defp confirmation(config, opts) do
    valid =
      Keyword.keyword?(opts) and
        Enum.all?(Keyword.keys(opts), &(&1 in [:out, :execute, :approval_ref, :transport])) and
        opts[:execute] == config.digest and is_binary(opts[:approval_ref]) and
        String.trim(opts[:approval_ref]) != "" and is_binary(opts[:out])

    if valid, do: :ok, else: {:error, :execution_confirmation_required}
  end

  defp execute(context) do
    implementation = scenario(context.config.provider)
    observations = run_scenario(implementation, context)
    assertions = implementation.assess(context, observations)
    {:ok, coverage} = Coverage.new(context.config, nil, observations)
    {:ok, consumption} = Consumption.new(nil, 0)
    {:ok, cleanup} = Cleanup.new(context.config, nil)

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
         {:ok, cleanup} <- Cleanup.new(context.config, capture) do
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
  defp evidence_provider(:agentcore), do: :agentcore
  defp evidence_provider(:claude_managed_agents), do: :managed
end
