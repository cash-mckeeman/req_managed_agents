defmodule ReqManagedAgents.Providers.BedrockAgentCore do
  @moduledoc """
  `ReqManagedAgents.Provider` for the Bedrock AgentCore backend — `:request_response` mode.
  Each turn is one `InvokeHarness` call; resume re-sends the assistant `toolUse` + user
  `toolResult` delta (the harness does not persist the uncommitted tool-use turn). Composes
  the existing `AgentCore.{Client, Converse}` modules.
  """
  @behaviour ReqManagedAgents.Provider

  alias ReqManagedAgents.AgentCore.{Client, Converse}

  @impl true
  def mode, do: :request_response

  @impl true
  def open(opts, _subscriber) do
    {:ok,
     %{
       harness_arn: Keyword.fetch!(opts, :harness_arn),
       sid: Keyword.fetch!(opts, :runtime_session_id),
       model: opts[:model],
       retries: opts[:invoke_retries] || 2,
       # Build the real client (which reads AWS creds) ONLY when no invoke_fun is injected.
       invoke_fun: opts[:invoke_fun] || default_invoke_fun(opts)
     }}
  end

  defp default_invoke_fun(opts) do
    client = opts[:client] || Client.new()
    fn inv -> Client.invoke_harness(client, inv) end
  end

  @impl true
  def kickoff_input(opts),
    do: [%{"role" => "user", "content" => [%{"text" => opts[:prompt] || "Begin."}]}]

  @impl true
  def user_input(text), do: [%{"role" => "user", "content" => [%{"text" => text}]}]

  @impl true
  def resume_input(custom_tool_uses, results) do
    wire =
      Enum.map(custom_tool_uses, fn %{id: id, name: name, input: input} ->
        %{"toolUseId" => id, "name" => name, "input" => input}
      end)

    Converse.resume_messages(wire, results)
  end

  @impl true
  def poll_turn(conn, messages), do: invoke(conn, messages, conn.retries)

  # One turn with bounded retry on a transport error or a truncated stream (stop_reason == nil).
  # A surfaced AWS exception/error frame is never retried.
  defp invoke(conn, messages, retries_left) do
    inv = %{harness_arn: conn.harness_arn, runtime_session_id: conn.sid, messages: messages, model: conn.model}

    case conn.invoke_fun.(inv) do
      {:ok, events} ->
        case stream_error(events) do
          {type, message} ->
            {:error, {:harness_stream_error, type, message}}

          nil ->
            if normalize(events).stop_reason != nil or retries_left == 0 do
              {:ok, events, conn}
            else
              invoke(conn, messages, retries_left - 1)
            end
        end

      {:error, _reason} when retries_left > 0 ->
        invoke(conn, messages, retries_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def normalize(events) do
    %{stop_reason: reason, tool_uses: tool_uses, text: text} = Converse.parse(events)

    custom_tool_uses =
      Enum.map(tool_uses, fn %{"toolUseId" => id, "name" => name, "input" => input} ->
        %{id: id, name: name, input: input}
      end)

    %{
      terminal: terminal(reason),
      stop_reason: reason,
      custom_tool_uses: custom_tool_uses,
      # Harness built-in tools execute in-microVM and do not surface a modelable event yet.
      server_tool_uses: [],
      text: text,
      events: events
    }
  end

  @doc false
  def terminal("end_turn"), do: :end_turn
  def terminal("stop_sequence"), do: :end_turn
  def terminal("tool_use"), do: :requires_action
  def terminal(_other), do: :terminated

  # A surfaced AWS exception/error frame (EventStream tags it __stream_error__), if any.
  defp stream_error(events) do
    Enum.find_value(events, fn
      %{"__stream_error__" => %{"type" => t, "message" => m}} -> {t, stream_error_message(m)}
      _ -> nil
    end)
  end

  defp stream_error_message(%{"message" => msg}) when is_binary(msg), do: msg
  defp stream_error_message(other), do: other
end
