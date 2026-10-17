defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Recovery do
  @moduledoc "Links native CMA tool results by their declared tool-use key within one acquisition source and an explicit native thread or verified primary thread endpoint. Missing or conflicting identity is inconclusive."
  @behaviour ReqManagedAgents.Acceptance.Recovery
  alias ReqManagedAgents.Acceptance.RecoveryAttempt
  alias ReqManagedAgents.Evidence.{Capture, Record, Source, Validation}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.History

  defmodule Qualification do
    @moduledoc false
    @enforce_keys [:session_id, :source_id, :thread_id, :descriptor_reference]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            session_id: String.t(),
            source_id: String.t(),
            thread_id: String.t(),
            descriptor_reference: String.t()
          }
  end

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
  @spec source_attempts(Capture.t(), Source.t()) ::
          {:ok, [RecoveryAttempt.t()], [String.t()]} | {:error, :inconclusive}
  def source_attempts(%Capture{provider: :managed} = capture, %Source{} = source) do
    scoped = %{capture | sources: [source], records: source_records(capture, source)}

    case {source.kind, clean_source?(capture, source)} do
      {:claude_session, true} ->
        with {:ok, attempts} <- attempts(scoped), do: {:ok, attempts, []}

      {:claude_thread, true} ->
        with {:ok, context} <- qualification(capture, source),
             {:ok, attempts} <- interpret(scoped, context) do
          {:ok, attempts, [context.descriptor_reference]}
        end

      _ ->
        {:error, :inconclusive}
    end
  end

  def source_attempts(_, _), do: {:error, :inconclusive}

  defp qualification(capture, source) do
    enumerations =
      Enum.filter(capture.sources, fn candidate ->
        candidate.kind == :claude_thread and
          candidate.scope == History.thread_enumeration_scope(capture.session_id)
      end)

    with {:ok, session} <- Validation.id(capture.session_id),
         [enumeration] <- enumerations,
         true <- enumeration.id != source.id and clean_source?(capture, enumeration),
         descriptors = source_records(capture, enumeration),
         true <- descriptors != [] and enumeration.records_seen == length(descriptors),
         true <- Enum.all?(descriptors, &valid_descriptor?(&1, session)),
         ids = Enum.map(descriptors, & &1.payload["id"]),
         true <- length(ids) == length(Enum.uniq(ids)),
         [primary] <- Enum.filter(descriptors, &is_nil(&1.payload["parent_thread_id"])),
         thread = primary.payload["id"],
         [candidate] <-
           Enum.filter(capture.sources, &(&1.kind == :claude_thread and &1.scope == thread)),
         true <- candidate == source do
      {:ok,
       %Qualification{
         session_id: session,
         source_id: source.id,
         thread_id: thread,
         descriptor_reference: enumeration.id <> ":" <> primary.id
       }}
    else
      _ -> {:error, :inconclusive}
    end
  end

  defp valid_descriptor?(%Record{kind: :native, payload: payload}, session) do
    payload["type"] == "session_thread" and payload["session_id"] == session and
      match?({:ok, _}, Validation.id(payload["id"])) and
      Map.has_key?(payload, "parent_thread_id") and
      (is_nil(payload["parent_thread_id"]) or
         match?({:ok, _}, Validation.id(payload["parent_thread_id"])))
  end

  defp valid_descriptor?(_, _), do: false

  defp clean_source?(capture, source) do
    source.status == :complete and
      not Enum.any?(capture.diagnostics, &(is_nil(&1.source_id) or &1.source_id == source.id))
  end

  defp source_records(capture, source),
    do: Enum.filter(capture.records, &(&1.source_id == source.id))

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

    interpret(%{capture | records: native}, nil)
  end

  def attempts(_), do: {:error, :inconclusive}

  defp interpret(%Capture{session_id: session, records: records}, context) do
    native = Enum.filter(records, &(&1.kind == :native))

    relevant =
      Enum.filter(
        native,
        &(Map.has_key?(@uses, &1.payload["type"]) or Map.has_key?(@results, &1.payload["type"]))
      )

    uses = Enum.filter(relevant, &Map.has_key?(@uses, &1.payload["type"]))
    results = Enum.filter(relevant, &Map.has_key?(@results, &1.payload["type"]))
    identities = Enum.map(relevant, &{&1.source_id, &1.payload["id"]})

    if length(identities) == length(Enum.uniq(identities)) and length(uses) == length(results) do
      Enum.reduce_while(uses, {:ok, []}, &append_attempt(&1, &2, results, session, context))
    else
      {:error, :inconclusive}
    end
  end

  defp append_attempt(use, {:ok, attempts}, results, session, context) do
    case link(use, results, session, context) do
      {:ok, attempt} -> {:cont, {:ok, attempts ++ [attempt]}}
      _ -> {:halt, {:error, :inconclusive}}
    end
  end

  defp link(%Record{} = use, results, session, context) do
    family = @uses[use.payload["type"]]

    matching =
      Enum.filter(results, fn result ->
        {result_family, key} = @results[result.payload["type"]]

        result.source_id == use.source_id and result_family == family and
          result.payload[key] == use.payload["id"]
      end)

    with [result] <- matching,
         true <- same_session?(use, session) and same_session?(result, session),
         {:ok, thread} <- native_thread(use, context),
         {:ok, ^thread} <- native_thread(result, context),
         flag when is_boolean(flag) <- result.payload["is_error"] do
      RecoveryAttempt.new(%{
        session_id: session,
        source_id: use.source_id,
        thread_id: thread,
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

  defp native_thread(%Record{source_id: source, payload: payload}, %Qualification{
         source_id: source,
         thread_id: thread
       }) do
    hints = Map.take(payload, ~w(session_thread_id thread_id))

    if Enum.all?(hints, fn {_, hint} -> hint == thread end),
      do: {:ok, thread},
      else: {:error, :inconclusive}
  end

  defp native_thread(%Record{payload: payload}, nil) do
    identities =
      payload
      |> Map.take(~w(session_thread_id thread_id))
      |> Map.values()
      |> Enum.uniq()

    case identities do
      [thread] -> Validation.id(thread)
      _ -> {:error, :inconclusive}
    end
  end

  defp same_session?(%Record{payload: payload}, session),
    do: Map.get(payload, "session_id", session) == session
end
