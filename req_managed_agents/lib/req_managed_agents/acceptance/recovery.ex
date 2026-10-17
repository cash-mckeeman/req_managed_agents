defmodule ReqManagedAgents.Acceptance.Recovery do
  @moduledoc "Assesses recovery only from explicitly linked, source-scoped native attempts from a complete qualifying acquisition in one capture."
  alias ReqManagedAgents.Acceptance.{Assertion, RecoveryAttempt}
  alias ReqManagedAgents.Evidence.{Capture, Source, Validation}
  alias ReqManagedAgents.Providers.BedrockAgentCore.Recovery, as: AgentCore
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Recovery, as: ClaudeManagedAgents

  @callback attempts(Capture.t()) :: {:ok, [RecoveryAttempt.t()]} | {:error, :inconclusive}

  @doc "Qualifies attempts from one selected source using full acquisition context; absent implementations use scoped attempts/1 with no support references."
  @callback source_attempts(Capture.t(), Source.t()) ::
              {:ok, [RecoveryAttempt.t()], [String.t()]} | {:error, :inconclusive}
  @optional_callbacks source_attempts: 2

  @doc "Arguments are decoded expected native JSON; absent or ambiguous native facts remain inconclusive."
  @spec assess(Capture.t(), String.t(), map()) ::
          {:ok, Assertion.t()} | {:error, :invalid_expectation}
  def assess(capture, target, arguments), do: assess(capture, target, arguments, nil)

  @doc "Optionally restrict the native attempt family without remapping provider records."
  @spec assess(Capture.t(), String.t(), map(), :builtin | :custom | :mcp | nil) ::
          {:ok, Assertion.t()} | {:error, :invalid_expectation}
  def assess(%Capture{} = capture, target, arguments, family)
      when is_binary(target) and is_map(arguments) do
    if target != "" and Validation.json?(arguments) and family in [nil, :builtin, :custom, :mcp] do
      evidence = recovered(capture, target, arguments, family)

      Assertion.new(
        "native_tool_recovery",
        if(evidence == [], do: :inconclusive, else: :passed),
        evidence
      )
    else
      {:error, :invalid_expectation}
    end
  end

  def assess(_, _, _, _), do: {:error, :invalid_expectation}

  defp recovered(%Capture{session_id: session} = capture, target, arguments, family)
       when is_binary(session) do
    if Enum.any?(capture.diagnostics, &is_nil(&1.source_id)) do
      []
    else
      capture.sources
      |> Enum.filter(&(&1.status == :complete))
      |> Enum.find_value([], &qualifying_evidence(capture, &1, target, arguments, family))
    end
  end

  defp recovered(_, _, _, _), do: []

  defp qualifying_evidence(capture, source, target, arguments, family) do
    case source_recovery(capture, source, target, arguments, family) do
      [] -> nil
      evidence -> evidence
    end
  end

  defp source_recovery(capture, source, target, arguments, family) do
    interpreter = if capture.provider == :managed, do: ClaudeManagedAgents, else: AgentCore

    with false <- Enum.any?(capture.diagnostics, &(&1.source_id == source.id)),
         {:ok, attempts, support} <- source_attempts(interpreter, capture, source),
         matching =
           Enum.filter(
             attempts,
             &(&1.target == target and &1.arguments === arguments and
                 (is_nil(family) or &1.family == family))
           ),
         [first, second] <- Enum.sort_by(matching, &DateTime.to_unix(&1.started_at, :microsecond)),
         true <- pair?(first, second) do
      first.evidence ++ second.evidence ++ support
    else
      _ -> []
    end
  end

  # Providers without acquisition-context qualification retain the scoped callback.
  defp source_attempts(interpreter, capture, source) do
    if Code.ensure_loaded?(interpreter) and
         function_exported?(interpreter, :source_attempts, 2) do
      interpreter.source_attempts(capture, source)
    else
      scoped = %{
        capture
        | sources: [source],
          records: Enum.filter(capture.records, &(&1.source_id == source.id)),
          diagnostics: Enum.filter(capture.diagnostics, &(&1.source_id == source.id))
      }

      with [] <- scoped.diagnostics,
           {:ok, attempts} <- interpreter.attempts(scoped) do
        {:ok, attempts, []}
      else
        _ -> {:error, :inconclusive}
      end
    end
  end

  defp pair?(%RecoveryAttempt{} = first, %RecoveryAttempt{} = second) do
    first.session_id == second.session_id and first.source_id == second.source_id and
      first.thread_id == second.thread_id and first.family == second.family and
      first.use_id != second.use_id and
      first.result_id != second.result_id and first.outcome == :failed and
      second.outcome == :passed and
      DateTime.compare(first.ended_at, second.started_at) == :lt
  end
end
