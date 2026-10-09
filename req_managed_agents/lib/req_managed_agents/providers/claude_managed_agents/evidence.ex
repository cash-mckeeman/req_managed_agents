defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Evidence do
  @moduledoc "Safe interpretation of native ClaudeManagedAgents evidence; content retention remains shared."
  @behaviour ReqManagedAgents.Evidence.Adapter
  alias ReqManagedAgents.Evidence.{NativeObservation, Validation}

  @doc "Extracts native facts and a metadata-only projection without retaining content."
  @impl true
  @spec interpret(map()) :: NativeObservation.t()
  def interpret(payload) when is_map(payload) do
    if Validation.json?(payload),
      do: interpret_json(payload),
      else: %NativeObservation{supported?: false, malformed_metadata?: true, safe_payload: %{}}
  end

  defp interpret_json(payload) do
    {:ok, observation} =
      NativeObservation.new(%{
        supported?: supported?(payload),
        malformed_metadata?: malformed_metadata?(payload) or malformed_id?(payload),
        native_id: native_id(payload),
        occurred_at: occurred_at(payload),
        safe_payload: metadata(payload)
      })

    observation
  end

  defp malformed_id?(payload),
    do: Map.get(payload, "id") != nil and native_id(payload) == nil

  defp native_id(payload) do
    case Validation.id(Map.get(payload, "id")) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  defp occurred_at(payload) do
    case Validation.utc(Map.get(payload, "processed_at")) do
      {:ok, time} -> time
      _ -> nil
    end
  end

  @claude_types ~w(agent.message agent.custom_tool_use agent.tool_use agent.tool_result user.message
    user.custom_tool_result agent.mcp_tool_use agent.mcp_tool_result user.tool_result
    user.tool_confirmation session.status_idle session.status_running session.status_terminated
    session.error span.model_request_start span.model_request_end)
  @strings ~w(id session_id thread_id span_id parent_span_id tool_use_id name status stop_reason model_request_start_id mcp_tool_use_id custom_tool_use_id session_thread_id from_session_thread_id to_session_thread_id)
  @times ~w(created_at timestamp started_at ended_at processed_at)
  @usage ~w(input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens total_tokens
    inputTokens outputTokens totalTokens)

  defp supported?(%{"type" => type}) when type in @claude_types, do: true
  defp supported?(_), do: false

  defp malformed_metadata?(%{"type" => type} = payload) when type in @claude_types do
    malformed_fields?(payload, @strings, &is_binary/1) or
      malformed_fields?(payload, @times, &match?({:ok, _}, Validation.utc(&1))) or
      malformed_fields?(payload, ["usage", "model_usage"], &valid_usage?/1)
  end

  defp malformed_metadata?(_), do: false

  defp malformed_fields?(payload, keys, valid?) do
    Enum.any?(keys, fn key ->
      case Map.fetch(payload, key) do
        :error -> false
        {:ok, nil} -> false
        {:ok, value} -> not valid?.(value)
      end
    end)
  end

  defp valid_usage?(usage) when is_map(usage),
    do: not malformed_fields?(usage, @usage, &nonnegative_number?/1)

  defp valid_usage?(_), do: false

  defp metadata(%{"type" => type} = payload) when type in @claude_types do
    payload
    |> strings(["type" | @strings])
    |> Map.merge(times(payload))
    |> usage(payload, "usage")
    |> usage(payload, "model_usage")
  end

  defp metadata(_), do: %{}

  defp strings(payload, fields) do
    payload
    |> Map.take(fields)
    |> Map.filter(fn {_, value} -> is_binary(value) end)
  end

  defp numeric(payload), do: Map.filter(payload, fn {_, v} -> nonnegative_number?(v) end)

  defp times(payload) do
    payload
    |> Map.take(@times)
    |> Map.filter(fn {_, value} ->
      match?({:ok, _}, Validation.utc(value))
    end)
  end

  defp usage(result, payload, key) do
    case Map.get(payload, key) do
      value when is_map(value) -> Map.put(result, key, numeric(Map.take(value, @usage)))
      _ -> result
    end
  end

  defp nonnegative_number?(value), do: is_number(value) and value >= 0
end
