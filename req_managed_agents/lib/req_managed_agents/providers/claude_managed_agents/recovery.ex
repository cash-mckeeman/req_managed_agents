defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Recovery do
  @moduledoc "Links native CMA tool results by their declared tool-use key within one acquisition source."
  @behaviour ReqManagedAgents.Acceptance.Recovery
  alias ReqManagedAgents.Acceptance.RecoveryAttempt
  alias ReqManagedAgents.Evidence.{Capture, Record}

  @uses %{
    "agent.tool_use" => :builtin,
    "agent.custom_tool_use" => :custom,
    "agent.mcp_tool_use" => :mcp
  }
  @results %{
    "agent.tool_result" => {:builtin, "tool_use_id"},
    "user.custom_tool_result" => {:custom, "custom_tool_use_id"},
    "agent.mcp_tool_result" => {:mcp, "mcp_tool_use_id"}
  }

  @impl true
  @spec attempts(Capture.t()) :: {:ok, [RecoveryAttempt.t()]} | {:error, :inconclusive}
  def attempts(%Capture{provider: :managed, session_id: session} = capture)
      when is_binary(session) do
    sources = Map.new(capture.sources, &{&1.id, &1.kind})

    native =
      Enum.filter(
        capture.records,
        &(&1.kind == :native and Map.get(sources, &1.source_id) == :claude_session)
      )

    relevant =
      Enum.filter(
        native,
        &(Map.has_key?(@uses, &1.payload["type"]) or Map.has_key?(@results, &1.payload["type"]))
      )

    uses = Enum.filter(relevant, &Map.has_key?(@uses, &1.payload["type"]))
    results = Enum.filter(relevant, &Map.has_key?(@results, &1.payload["type"]))
    identities = Enum.map(relevant, &{&1.source_id, &1.payload["id"]})

    if length(identities) == length(Enum.uniq(identities)) and length(uses) == length(results) do
      Enum.reduce_while(uses, {:ok, []}, &append_attempt(&1, &2, results, session))
    else
      {:error, :inconclusive}
    end
  end

  def attempts(_), do: {:error, :inconclusive}

  defp append_attempt(use, {:ok, attempts}, results, session) do
    case link(use, results, session) do
      {:ok, attempt} -> {:cont, {:ok, attempts ++ [attempt]}}
      _ -> {:halt, {:error, :inconclusive}}
    end
  end

  defp link(%Record{} = use, results, session) do
    family = @uses[use.payload["type"]]

    matching =
      Enum.filter(results, fn result ->
        {result_family, key} = @results[result.payload["type"]]

        result.source_id == use.source_id and result_family == family and
          result.payload[key] == use.payload["id"]
      end)

    with [result] <- matching,
         true <- same_session?(use, session) and same_session?(result, session),
         flag when is_boolean(flag) <- result.payload["is_error"] do
      RecoveryAttempt.new(%{
        session_id: session,
        source_id: use.source_id,
        use_id: use.payload["id"],
        result_id: result.payload["id"],
        family: family,
        target: use.payload["name"],
        arguments: use.payload["input"],
        started_at: use.payload["processed_at"],
        ended_at: result.payload["processed_at"],
        outcome: if(flag, do: :failed, else: :passed),
        evidence: [use.source_id <> ":" <> use.id, result.source_id <> ":" <> result.id]
      })
    else
      _ -> {:error, :inconclusive}
    end
  end

  defp same_session?(%Record{payload: payload}, session),
    do: Map.get(payload, "session_id", session) == session
end
