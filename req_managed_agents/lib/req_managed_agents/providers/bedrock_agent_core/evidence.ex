defmodule ReqManagedAgents.Providers.BedrockAgentCore.Evidence do
  @moduledoc "Safe interpretation of native BedrockAgentCore evidence; content retention remains shared."
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
        malformed_metadata?: malformed_metadata?(payload),
        native_id: native_id(payload),
        safe_payload: metadata(payload)
      })

    observation
  end

  defp native_id(payload) do
    case Validation.id(Map.get(payload, "id")) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  @stream_fields ~w(messageStart messageStop contentBlockStart contentBlockDelta contentBlockStop metadata)
  @trace_strings ~w(traceId spanId parentSpanId name)
  @trace_times ~w(startTimeUnixNano endTimeUnixNano)
  @usage ~w(input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens total_tokens
    inputTokens outputTokens totalTokens)

  defp supported?(%{"messageStart" => value}) when is_map(value), do: true
  defp supported?(%{"messageStop" => value}) when is_map(value), do: true
  defp supported?(%{"contentBlockStart" => value}) when is_map(value), do: true
  defp supported?(%{"contentBlockDelta" => value}) when is_map(value), do: true
  defp supported?(%{"contentBlockStop" => value}) when is_map(value), do: true
  defp supported?(%{"metadata" => %{"usage" => usage}}) when is_map(usage), do: true

  defp supported?(%{"traceId" => trace, "spanId" => span})
       when is_binary(trace) and is_binary(span), do: true

  defp supported?(_), do: false

  defp malformed_metadata?(%{"traceId" => _, "spanId" => _} = payload) do
    malformed_fields?(payload, @trace_strings, &is_binary/1) or
      malformed_fields?(payload, @trace_times, &nonnegative_number?/1)
  end

  defp malformed_metadata?(payload) do
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

  defp metadata(%{"traceId" => _, "spanId" => _} = payload) do
    times = numeric(Map.take(payload, @trace_times))

    payload
    |> strings(@trace_strings)
    |> Map.merge(times)
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

  defp usage(result, payload, key) do
    case Map.get(payload, key) do
      value when is_map(value) -> Map.put(result, key, numeric(Map.take(value, @usage)))
      _ -> result
    end
  end
end
