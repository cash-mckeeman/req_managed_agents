defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Evidence do
  @moduledoc "Safe interpretation of native ClaudeManagedAgents evidence; content retention remains shared."
  @behaviour ReqManagedAgents.Evidence.Adapter
  alias ReqManagedAgents.Evidence.{NativeObservation, Validation}

  @native_metadata_types ~w(session.thread_status_running session.thread_status_idle session.usage)
  @activity_types ~w(agent.thinking session.thread_created agent.thread_message_sent agent.thread_message_received)
  @session_usage [
    {"active_seconds", :number},
    {"cache_creation",
     [{"ephemeral_1h_input_tokens", :counter}, {"ephemeral_5m_input_tokens", :counter}]},
    {"cache_read_input_tokens", :counter},
    {"input_tokens", :counter},
    {"output_tokens", :counter},
    {"list_cost", :money},
    {"server_tool_use", [{"web_fetch_requests", :counter}, {"web_search_requests", :counter}]}
  ]

  @doc "Extracts native facts and a metadata-only projection without retaining content."
  @impl true
  @spec interpret(map()) :: NativeObservation.t()
  def interpret(payload) when is_map(payload) do
    if Validation.json?(payload),
      do: interpret_json(payload),
      else: %NativeObservation{supported?: false, malformed_metadata?: true, safe_payload: %{}}
  end

  defp interpret_json(payload) do
    {safe, malformed?} = projection(payload)

    {:ok, observation} =
      NativeObservation.new(%{
        supported?: supported?(payload),
        malformed_metadata?: malformed?,
        native_id: native_id(payload),
        occurred_at: occurred_at(payload),
        safe_payload: safe
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
  @strings ~w(id session_id thread_id span_id parent_span_id tool_use_id name status model_request_start_id mcp_tool_use_id custom_tool_use_id session_thread_id from_session_thread_id to_session_thread_id)
  @times ~w(created_at timestamp started_at ended_at processed_at)
  @usage ~w(input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens total_tokens
    inputTokens outputTokens totalTokens)

  defp supported?(%{"type" => "session_thread"}), do: true
  defp supported?(%{"type" => type}) when type in @activity_types, do: true
  defp supported?(%{"type" => type}) when type in @native_metadata_types, do: true
  defp supported?(%{"type" => type}) when type in @claude_types, do: true
  defp supported?(_), do: false

  # These maps are decoded provider JSON projected at the native wire boundary.
  defp projection(%{"type" => type} = payload) when type in @activity_types do
    required =
      case type do
        "agent.thinking" -> ~w(id processed_at)
        "session.thread_created" -> ~w(id processed_at session_thread_id)
        "agent.thread_message_sent" -> ~w(id processed_at to_session_thread_id)
        "agent.thread_message_received" -> ~w(id processed_at from_session_thread_id)
      end

    fields = Enum.map(required, &{&1, if(&1 == "processed_at", do: :time, else: :id)})

    fields =
      if type == "session.thread_created",
        do: fields,
        else: fields ++ [{"session_thread_id", :id}]

    {safe, malformed?} = project_fields(payload, fields)
    missing? = Enum.any?(required, &(not Map.has_key?(safe, &1)))
    {Map.put(safe, "type", type), malformed? or missing?}
  end

  # Session usage remains cumulative metadata, independent of per-turn metering.
  defp projection(%{"type" => type} = payload) when type in @native_metadata_types do
    fields = [{"id", :id}, {"processed_at", :time}]

    fields =
      case type do
        "session.usage" ->
          fields ++ [{"usage", @session_usage}, {"budget", :budget}]

        "session.thread_status_idle" ->
          fields ++ [{"session_thread_id", :id}, {"stop_reason", :reason}]

        _ ->
          fields ++ [{"session_thread_id", :id}]
      end

    required =
      if type == "session.usage",
        do: ~w(id processed_at usage),
        else: ~w(id processed_at session_thread_id)

    {safe, malformed?} = project_fields(payload, fields)
    missing? = Enum.any?(required, &(not Map.has_key?(safe, &1)))
    {Map.put(safe, "type", type), malformed? or missing?}
  end

  defp projection(payload),
    do: {metadata(payload), malformed_metadata?(payload) or malformed_id?(payload)}

  defp project_fields(payload, fields) do
    Enum.reduce(fields, {%{}, false}, fn {key, rule}, {safe, malformed?} ->
      case Map.fetch(payload, key) do
        :error -> {safe, malformed?}
        {:ok, nil} when rule == :budget -> {safe, malformed?}
        {:ok, value} -> project_field(safe, malformed?, key, value, rule)
      end
    end)
  end

  defp project_field(safe, malformed?, key, value, fields)
       when is_list(fields) and is_map(value) do
    {nested, invalid?} = project_fields(value, fields)
    {Map.put(safe, key, nested), malformed? or invalid?}
  end

  defp project_field(safe, malformed?, key, value, rule) do
    case project_value(value, rule) do
      {:ok, projected} -> {Map.put(safe, key, projected), malformed?}
      :error -> {safe, true}
    end
  end

  defp project_value(value, :id), do: validate(value, &valid_id?/1)
  defp project_value(value, :time), do: validate(value, &match?({:ok, _}, Validation.utc(&1)))
  defp project_value(value, :counter), do: validate(value, &(is_integer(&1) and &1 >= 0))
  defp project_value(value, :number), do: validate(value, &nonnegative_number?/1)

  defp project_value(%{"type" => type}, :reason) when is_binary(type) and byte_size(type) > 0,
    do: {:ok, %{"type" => type}}

  defp project_value(%{"amount" => amount, "currency" => "USD"} = value, :money)
       when is_binary(amount) do
    if Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, amount),
      do: {:ok, Map.take(value, ~w(amount currency))},
      else: :error
  end

  defp project_value(%{"type" => "limit", "max_list_cost" => cost}, :budget) do
    case project_value(cost, :money) do
      {:ok, money} -> {:ok, %{"type" => "limit", "max_list_cost" => money}}
      :error -> :error
    end
  end

  defp project_value(_, _), do: :error

  defp validate(value, valid?) do
    if valid?.(value), do: {:ok, value}, else: :error
  end

  defp valid_id?(value), do: match?({:ok, _}, Validation.id(value))

  defp malformed_metadata?(%{"type" => "session_thread"} = payload) do
    not valid_id?(Map.get(payload, "id")) or
      not valid_id?(Map.get(payload, "session_id")) or
      case Map.fetch(payload, "parent_thread_id") do
        {:ok, nil} -> false
        {:ok, parent} -> not valid_id?(parent)
        :error -> true
      end
  end

  defp malformed_metadata?(%{"type" => type} = payload) when type in @claude_types do
    malformed_fields?(payload, @strings, &is_binary/1) or
      malformed_fields?(payload, ["stop_reason"], &(normalize_stop_reason(&1) != nil)) or
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

  defp metadata(%{"type" => "session_thread"} = payload) do
    payload
    |> Map.take(~w(type id session_id parent_thread_id))
    |> Map.filter(fn
      {"type", _} -> true
      {"parent_thread_id", nil} -> true
      {_, value} -> valid_id?(value)
    end)
  end

  defp metadata(%{"type" => type} = payload) when type in @claude_types do
    payload
    |> strings(["type" | @strings])
    |> stop_reason(payload)
    |> Map.merge(times(payload))
    |> usage(payload, "usage")
    |> usage(payload, "model_usage")
  end

  defp metadata(_), do: %{}

  defp stop_reason(result, payload) do
    case normalize_stop_reason(Map.get(payload, "stop_reason")) do
      nil -> result
      reason -> Map.put(result, "stop_reason", reason)
    end
  end

  defp normalize_stop_reason(reason) when is_binary(reason), do: reason

  defp normalize_stop_reason(%{"type" => type}) when is_binary(type) and byte_size(type) > 0,
    do: %{"type" => type}

  defp normalize_stop_reason(_), do: nil

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
