defmodule ReqManagedAgents.Providers.BedrockAgentCore.CloudWatchLogs do
  @moduledoc """
  Qualifies flattened AgentCore log records for same-session association.

  Requires explicit `attributes.sessionId`, agreeing top-level and attribute
  trace/span IDs, integer nanosecond times, and an outer timestamp matching the
  event time in milliseconds. Bodies, request IDs and log destinations supply no
  identity or causal relationship. Unrecognized records remain unlinked.
  """
  @behaviour ReqManagedAgents.CloudWatch.MessageAssociation
  alias ReqManagedAgents.CloudWatch.Query

  @doc false
  @impl true
  @spec matches?(map(), Query.t()) :: boolean()
  def matches?(
        %{
          "eventId" => id,
          "logStreamName" => stream,
          "timestamp" => time,
          "ingestionTime" => ingestion,
          "message" => message
        },
        %Query{} = query
      )
      when is_binary(id) and id != "" and is_binary(stream) and is_binary(message) and
             is_integer(time) and is_integer(ingestion) and ingestion >= 0 do
    with true <-
           time >= DateTime.to_unix(query.from, :millisecond) and
             time <= DateTime.to_unix(query.to, :millisecond),
         {:ok, log} <- Jason.decode(message) do
      matching_log?(log, time, query)
    else
      _ -> false
    end
  end

  def matches?(_, _), do: false

  defp matching_log?(
         %{
           "resource" => %{"attributes" => resource},
           "scope" => %{"name" => scope},
           "severityText" => severity,
           "severityNumber" => number,
           "body" => body,
           "attributes" => %{
             "sessionId" => session,
             "otelTraceID" => trace_alias,
             "otelSpanID" => span_alias
           },
           "timeUnixNano" => time,
           "observedTimeUnixNano" => observed,
           "traceId" => trace,
           "spanId" => span
         } = log,
         millis,
         query
       ) do
    valid_envelope?(resource, scope, severity, number, body) and
      matching_identity?(session, trace, span, trace_alias, span_alias, query) and
      matching_time?(time, observed, millis) and valid_flags?(log)
  end

  defp matching_log?(_, _, _), do: false

  defp valid_envelope?(resource, scope, severity, number, body),
    do:
      is_map(resource) and is_binary(scope) and is_binary(severity) and
        is_integer(number) and number in 1..24 and is_binary(body)

  defp matching_identity?(session, trace, span, trace_alias, span_alias, query),
    do:
      session == query.session_id and Query.trace_id?(trace) and hex_span?(span) and
        agreeing_id?(trace, trace_alias) and agreeing_id?(span, span_alias) and
        selected_trace?(trace, query.trace_ids)

  defp matching_time?(time, observed, millis),
    do: nano?(time) and nano?(observed) and observed >= time and div(time, 1_000_000) == millis

  defp hex_span?(value),
    do:
      is_binary(value) and Regex.match?(~r/\A[0-9a-fA-F]{16}\z/, value) and
        value != String.duplicate("0", 16)

  defp agreeing_id?(id, alias_id),
    do: is_binary(alias_id) and String.downcase(id) == String.downcase(alias_id)

  defp nano?(value),
    do: is_integer(value) and value >= 0 and value <= 18_446_744_073_709_551_615

  defp valid_flags?(log) do
    case Map.fetch(log, "flags") do
      :error -> true
      {:ok, value} -> is_integer(value) and value in 0..255
    end
  end

  defp selected_trace?(_, []), do: true
  defp selected_trace?(trace, selected), do: Enum.any?(selected, &agreeing_id?(trace, &1))
end
