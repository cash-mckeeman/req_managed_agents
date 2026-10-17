defmodule ReqManagedAgents.Acceptance do
  @moduledoc "On-demand managed-provider acceptance with explicit source and configuration confirmation."
  alias ReqManagedAgents.Acceptance.{Config, Context, Output, Proposal, Report, Runner, Source}
  alias ReqManagedAgents.Evidence.{Options, Recorder}
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

        Runner.run(context)
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

  defp scenario(:agentcore), do: AgentCore
  defp scenario(:claude_managed_agents), do: ClaudeManagedAgents
  defp evidence_provider(:agentcore), do: :agentcore
  defp evidence_provider(:claude_managed_agents), do: :managed
end
