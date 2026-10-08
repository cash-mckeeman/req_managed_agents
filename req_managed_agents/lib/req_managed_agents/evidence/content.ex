defmodule ReqManagedAgents.Evidence.Content do
  @moduledoc false
  alias ReqManagedAgents.Evidence.{Record, Validation}

  @claude_types ~w(agent.message agent.custom_tool_use agent.tool_use agent.tool_result user.message
    user.custom_tool_result session.status_idle session.status_running session.status_terminated
    session.error span.model_request_start span.model_request_end)
  @strings ~w(id session_id thread_id span_id parent_span_id tool_use_id name status stop_reason model_request_start_id mcp_tool_use_id custom_tool_use_id session_thread_id from_session_thread_id to_session_thread_id)
  @times ~w(created_at timestamp started_at ended_at processed_at)
  @stream_fields ~w(messageStart messageStop contentBlockStart contentBlockDelta contentBlockStop metadata)
  @trace_strings ~w(traceId spanId parentSpanId name)
  @trace_times ~w(startTimeUnixNano endTimeUnixNano)
  @usage ~w(input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens total_tokens
    inputTokens outputTokens totalTokens)

  def apply(%Record{kind: :local} = record, _), do: record
  def apply(%Record{content_state: :retained} = record, :retain), do: record

  def apply(%Record{} = record, _) do
    state = if record.content_state == :redacted, do: :redacted, else: :dropped
    %{record | payload: metadata(record.payload), content_state: state}
  end

  def supported?(%{"type" => type}) when type in @claude_types, do: true
  def supported?(%{"messageStart" => value}) when is_map(value), do: true
  def supported?(%{"messageStop" => value}) when is_map(value), do: true
  def supported?(%{"contentBlockStart" => value}) when is_map(value), do: true
  def supported?(%{"contentBlockDelta" => value}) when is_map(value), do: true
  def supported?(%{"contentBlockStop" => value}) when is_map(value), do: true
  def supported?(%{"metadata" => %{"usage" => usage}}) when is_map(usage), do: true

  def supported?(%{"traceId" => trace, "spanId" => span})
      when is_binary(trace) and is_binary(span), do: true

  def supported?(_), do: false

  def malformed_metadata?(%{"type" => type} = payload) when type in @claude_types do
    malformed_fields?(payload, @strings, &is_binary/1) or
      malformed_fields?(payload, @times, &match?({:ok, _}, Validation.utc(&1))) or
      malformed_fields?(payload, ["usage", "model_usage"], &valid_usage?/1)
  end

  def malformed_metadata?(%{"traceId" => _, "spanId" => _} = payload) do
    malformed_fields?(payload, @trace_strings, &is_binary/1) or
      malformed_fields?(payload, @trace_times, &nonnegative_number?/1)
  end

  def malformed_metadata?(payload) do
    Enum.any?(@stream_fields, fn key ->
      malformed_fields?(payload, [key], &valid_stream_metadata?(key, &1))
    end)
  end

  defp valid_stream_metadata?("metadata", value) when is_map(value),
    do: not malformed_fields?(value, ["usage"], &valid_usage?/1)

  defp valid_stream_metadata?("contentBlockStart", value) when is_map(value) do
    valid_stream_fields?(value) and not malformed_fields?(value, ["start"], &valid_start?/1)
  end

  defp valid_stream_metadata?(_key, value) when is_map(value), do: valid_stream_fields?(value)
  defp valid_stream_metadata?(_key, _value), do: false

  defp valid_stream_fields?(value) do
    not malformed_fields?(value, ~w(role stopReason), &is_binary/1) and
      not malformed_fields?(value, ["contentBlockIndex"], &nonnegative_number?/1)
  end

  defp valid_start?(value) when is_map(value),
    do: not malformed_fields?(value, ["toolUse"], &valid_tool_metadata?/1)

  defp valid_start?(_), do: false

  defp valid_tool_metadata?(value) when is_map(value),
    do: not malformed_fields?(value, ~w(toolUseId name), &is_binary/1)

  defp valid_tool_metadata?(_), do: false

  defp nonnegative_number?(value), do: is_number(value) and value >= 0

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

  defp metadata(%{"traceId" => _, "spanId" => _} = payload) do
    payload
    |> strings(@trace_strings)
    |> Map.merge(Map.take(payload, @trace_times) |> numeric())
  end

  defp metadata(payload) do
    Enum.reduce(
      @stream_fields,
      %{},
      fn key, acc ->
        case Map.get(payload, key) do
          value when is_map(value) -> Map.put(acc, key, stream_metadata(key, value))
          _ -> acc
        end
      end
    )
  end

  defp stream_metadata("metadata", value), do: usage(%{}, value, "usage")

  defp stream_metadata("contentBlockStart", value) do
    index = numeric(Map.take(value, ["contentBlockIndex"]))

    case value do
      %{"start" => %{"toolUse" => tool}} when is_map(tool) ->
        Map.put(index, "start", %{"toolUse" => strings(tool, ~w(toolUseId name))})

      _ ->
        index
    end
  end

  defp stream_metadata(_, value) do
    Map.merge(
      strings(value, ~w(role stopReason)),
      numeric(Map.take(value, ["contentBlockIndex"]))
    )
  end

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
end
