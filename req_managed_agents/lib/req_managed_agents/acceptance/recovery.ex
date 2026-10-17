defmodule ReqManagedAgents.Acceptance.Recovery do
  @moduledoc "Assesses recovery only from explicitly linked, source-scoped native attempts from a complete qualifying acquisition in one capture."
  alias ReqManagedAgents.Acceptance.{Assertion, RecoveryAttempt}
  alias ReqManagedAgents.Evidence.{Capture, Validation}
  alias ReqManagedAgents.Providers.BedrockAgentCore.Recovery, as: AgentCore
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Recovery, as: ClaudeManagedAgents

  @callback attempts(Capture.t()) :: {:ok, [RecoveryAttempt.t()]} | {:error, :inconclusive}

  @doc "Arguments are decoded expected native JSON; absent or ambiguous native facts remain inconclusive."
  @spec assess(Capture.t(), String.t(), map()) ::
          {:ok, Assertion.t()} | {:error, :invalid_expectation}
  def assess(%Capture{} = capture, target, arguments)
      when is_binary(target) and is_map(arguments) do
    if target != "" and Validation.json?(arguments) do
      evidence = recovered(capture, target, arguments)

      Assertion.new(
        "native_tool_recovery",
        if(evidence == [], do: :inconclusive, else: :passed),
        evidence
      )
    else
      {:error, :invalid_expectation}
    end
  end

  def assess(_, _, _), do: {:error, :invalid_expectation}

  defp recovered(%Capture{session_id: session} = capture, target, arguments)
       when is_binary(session) do
    if Enum.any?(capture.diagnostics, &is_nil(&1.source_id)) do
      []
    else
      capture.sources
      |> Enum.filter(&(&1.status == :complete))
      |> Enum.find_value([], &qualifying_evidence(capture, &1, target, arguments))
    end
  end

  defp recovered(_, _, _), do: []

  defp qualifying_evidence(capture, source, target, arguments) do
    scoped = %{
      capture
      | sources: [source],
        records: Enum.filter(capture.records, &(&1.source_id == source.id)),
        diagnostics: Enum.filter(capture.diagnostics, &(&1.source_id == source.id))
    }

    case source_recovery(scoped, target, arguments) do
      [] -> nil
      evidence -> evidence
    end
  end

  defp source_recovery(%Capture{diagnostics: []} = capture, target, arguments) do
    interpreter = if capture.provider == :managed, do: ClaudeManagedAgents, else: AgentCore

    with {:ok, attempts} <- interpreter.attempts(capture),
         matching = Enum.filter(attempts, &(&1.target == target and &1.arguments === arguments)),
         [first, second] <- Enum.sort_by(matching, &DateTime.to_unix(&1.started_at, :microsecond)),
         true <- pair?(first, second) do
      first.evidence ++ second.evidence
    else
      _ -> []
    end
  end

  defp source_recovery(_, _, _), do: []

  defp pair?(%RecoveryAttempt{} = first, %RecoveryAttempt{} = second) do
    first.session_id == second.session_id and first.source_id == second.source_id and
      first.thread_id == second.thread_id and first.family == second.family and
      first.use_id != second.use_id and
      first.result_id != second.result_id and first.outcome == :failed and
      second.outcome == :passed and
      DateTime.compare(first.ended_at, second.started_at) == :lt
  end
end
