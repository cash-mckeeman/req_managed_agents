defmodule ReqManagedAgents.CloudWatch.Evidence do
  @moduledoc "Safe interpretation of legacy trace metadata collected from CloudWatch."
  @behaviour ReqManagedAgents.Evidence.Adapter
  alias ReqManagedAgents.Evidence.{NativeObservation, Validation}

  @strings ~w(traceId spanId parentSpanId name)
  @times ~w(startTimeUnixNano endTimeUnixNano)

  @doc "Projects trace identity and numeric bounds without attributes or content."
  @impl true
  @spec interpret(map()) :: NativeObservation.t()
  def interpret(payload) when is_map(payload) do
    if Validation.json?(payload),
      do: interpret_json(payload),
      else: %NativeObservation{supported?: false, malformed_metadata?: true, safe_payload: %{}}
  end

  defp interpret_json(%{"traceId" => trace, "spanId" => span} = payload) do
    {:ok, observation} =
      NativeObservation.new(%{
        supported?: is_binary(trace) and is_binary(span),
        malformed_metadata?: malformed?(payload),
        safe_payload: Map.merge(strings(payload), times(payload))
      })

    observation
  end

  defp interpret_json(_),
    do: %NativeObservation{supported?: false, malformed_metadata?: false, safe_payload: %{}}

  defp malformed?(payload) do
    Enum.any?(@strings, &invalid?(payload, &1, fn value -> is_binary(value) end)) or
      Enum.any?(@times, &invalid?(payload, &1, fn value -> nonnegative?(value) end))
  end

  defp invalid?(payload, key, valid?) do
    case Map.get(payload, key) do
      nil -> false
      value -> not valid?.(value)
    end
  end

  defp strings(payload) do
    payload
    |> Map.take(@strings)
    |> Map.filter(fn {_, value} -> is_binary(value) end)
  end

  defp times(payload) do
    payload
    |> Map.take(@times)
    |> Map.filter(fn {_, value} -> nonnegative?(value) end)
  end

  defp nonnegative?(value), do: is_number(value) and value >= 0
end
