defmodule ReqManagedAgents.CloudWatch.OTLP do
  @moduledoc "Same-session qualification of standard OTLP JSON span envelopes."
  @behaviour ReqManagedAgents.CloudWatch.MessageAssociation
  alias ReqManagedAgents.CloudWatch.Query

  @doc false
  @impl true
  @spec matches?(map(), Query.t()) :: boolean()
  def matches?(
        %{"eventId" => id, "logStreamName" => stream, "message" => message, "timestamp" => time} =
          payload,
        query
      )
      when is_binary(id) and id != "" and is_binary(stream) and is_binary(message) and
             is_integer(time) do
    with true <-
           time >= DateTime.to_unix(query.from, :millisecond) and
             time <= DateTime.to_unix(query.to, :millisecond),
         true <- is_integer(Map.get(payload, "ingestionTime")) and payload["ingestionTime"] >= 0,
         {:ok, %{"resourceSpans" => resources}} <- Jason.decode(message),
         true <- is_list(resources) and resources != [] do
      Enum.all?(resources, &matching_resource?(&1, query))
    else
      _ -> false
    end
  end

  def matches?(_, _), do: false

  defp matching_resource?(%{"scopeSpans" => scopes} = resource, query)
       when is_list(scopes) and scopes != [] do
    case Map.get(resource, "resource", %{}) do
      metadata when is_map(metadata) ->
        attrs = Map.get(metadata, "attributes", [])
        Enum.all?(scopes, &matching_scope?(&1, attrs, query))

      _ ->
        false
    end
  end

  defp matching_resource?(_, _), do: false

  defp matching_scope?(%{"spans" => spans}, attrs, query) when is_list(spans) and spans != [],
    do: Enum.all?(spans, &matching_span?(&1, attrs, query))

  defp matching_scope?(_, _, _), do: false

  defp matching_span?(
         %{
           "traceId" => trace,
           "spanId" => span,
           "name" => name,
           "startTimeUnixNano" => from,
           "endTimeUnixNano" => to
         } = value,
         resource,
         query
       ) do
    with true <- Query.trace_id?(trace) and hex_span?(span) and is_binary(name),
         true <-
           Map.get(value, "parentSpanId") in [nil, ""] or
             hex_span?(Map.get(value, "parentSpanId")),
         {:ok, from} <- nano(from),
         {:ok, to} <- nano(to),
         true <- from <= to,
         {:ok, ids} <- session_ids(resource),
         {:ok, span_ids} <- session_ids(Map.get(value, "attributes", [])),
         true <- Enum.uniq(ids ++ span_ids) == [query.session_id] do
      query.trace_ids == [] or
        Enum.any?(query.trace_ids, &(String.downcase(&1) == String.downcase(trace)))
    else
      _ -> false
    end
  end

  defp matching_span?(_, _, _), do: false

  defp hex_span?(value),
    do:
      is_binary(value) and Regex.match?(~r/\A[0-9a-fA-F]{16}\z/, value) and
        value != String.duplicate("0", 16)

  defp nano(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 and number <= 18_446_744_073_709_551_615 -> {:ok, number}
      _ -> :error
    end
  end

  defp nano(_), do: :error

  defp session_ids(attributes) when is_list(attributes) do
    Enum.reduce_while(attributes, {:ok, []}, fn
      %{"key" => "session.id", "value" => %{"stringValue" => id} = value}, {:ok, ids}
      when is_binary(id) and map_size(value) == 1 ->
        {:cont, {:ok, ids ++ [id]}}

      %{"key" => "session.id"}, _ ->
        {:halt, :error}

      %{"key" => key, "value" => value}, acc when is_binary(key) and is_map(value) ->
        {:cont, acc}

      _, _ ->
        {:halt, :error}
    end)
  end

  defp session_ids(_), do: :error
end
