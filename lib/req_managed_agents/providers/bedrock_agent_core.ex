defmodule ReqManagedAgents.Providers.BedrockAgentCore do
  @moduledoc """
  `ReqManagedAgents.Provider` for the Bedrock AgentCore backend — `:request_response` mode.
  Each turn is one `InvokeHarness` call; resume re-sends the assistant `toolUse` + user
  `toolResult` delta (the harness does not persist the uncommitted tool-use turn). Composes
  the existing `AgentCore.{Client, Converse}` modules. Decoded events are additionally
  delivered live to the session as `{:provider_event, ev}` messages while a turn streams.
  The provision spec may carry opaque `environment`/`environment_variables` maps that pass
  through to CreateHarness verbatim (filesystem mounts, custom containers, env vars — never
  interpreted by this library).
  """
  @behaviour ReqManagedAgents.Provider

  alias ReqManagedAgents.AgentCore.{Client, Converse}
  alias ReqManagedAgents.{ToolUse, TurnResult, Usage}

  @impl true
  def mode, do: :request_response

  @ready_poll_ms 5_000
  @ready_max_polls 72
  @nonreusable_status ~w(DELETING DELETE_FAILED CREATE_FAILED UPDATE_FAILED)

  @impl true
  def provision(spec, opts) do
    name = harness_name(spec, opts[:name_prefix])

    harness_spec = %{
      name: name,
      execution_role_arn: Keyword.fetch!(opts, :execution_role_arn),
      system_prompt: spec.system_prompt,
      model: spec.model_config,
      tools: spec.tools,
      environment: Map.get(spec, :environment),
      environment_variables: Map.get(spec, :environment_variables)
    }

    create_fun =
      opts[:create_fun] || fn s -> Client.create_harness(opts[:client] || Client.new(), s) end

    list_fun = opts[:list_fun] || fn -> Client.list_harnesses(opts[:client] || Client.new()) end

    get_fun =
      opts[:get_fun] || fn hid -> Client.get_harness(opts[:client] || Client.new(), hid) end

    poll_ms = opts[:ready_poll_ms] || @ready_poll_ms
    max_polls = opts[:ready_max_polls] || @ready_max_polls

    case create_fun.(harness_spec) do
      # CreateHarness returns the created resource wrapped under "harness" (verified live against
      # bedrock-agentcore-control), consistent with GetHarness — NOT a flat "harnessArn".
      {:ok, %{"harness" => %{"arn" => arn, "harnessId" => hid}}} ->
        with :ok <- wait_until_ready(get_fun, hid, poll_ms, max_polls),
             do: {:ok, %{harness_arn: arn, harness_id: hid}}

      {:error, {:http_error, 409, _}} ->
        recover_existing(list_fun, get_fun, name, poll_ms, max_polls)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def teardown(%{harness_id: hid}, opts) do
    delete_fun =
      opts[:delete_fun] || fn id -> Client.delete_harness(opts[:client] || Client.new(), id) end

    case delete_fun.(hid) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def harness_name(spec, prefix) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(spec, [:deterministic]))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    [prefix, "harness_#{digest}"] |> Enum.reject(&is_nil/1) |> Enum.join("_")
  end

  defp recover_existing(list_fun, get_fun, name, poll_ms, max_polls) do
    with {:ok, %{"harnesses" => harnesses}} <- list_fun.(),
         %{"arn" => arn, "harnessId" => hid} <- recoverable_harness(harnesses, name),
         :ok <- wait_until_ready(get_fun, hid, poll_ms, max_polls) do
      {:ok, %{harness_arn: arn, harness_id: hid}}
    else
      nil -> {:error, {:harness_name_conflict, name}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_list_response, other}}
    end
  end

  defp recoverable_harness(harnesses, name) do
    Enum.find(harnesses, fn h ->
      h["harnessName"] == name and h["status"] not in @nonreusable_status
    end)
  end

  defp wait_until_ready(get_fun, hid, poll_ms, polls_left) do
    case get_fun.(hid) do
      {:ok, %{"harness" => %{"status" => "READY"}}} ->
        :ok

      {:ok, %{"harness" => %{"status" => s}}}
      when s in ["CREATE_FAILED", "UPDATE_FAILED", "DELETE_FAILED"] ->
        {:error, {:harness_failed, s}}

      {:ok, %{"harness" => %{"status" => _}}} when polls_left > 0 ->
        Process.sleep(poll_ms)
        wait_until_ready(get_fun, hid, poll_ms, polls_left - 1)

      {:ok, %{"harness" => _}} when polls_left == 0 ->
        {:error, :harness_ready_timeout}

      {:ok, other} ->
        {:error, {:unexpected_get_harness_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def open(opts, subscriber) do
    {:ok,
     %{
       harness_arn: Keyword.fetch!(opts, :harness_arn),
       sid: Keyword.fetch!(opts, :runtime_session_id),
       session_id: Keyword.fetch!(opts, :runtime_session_id),
       model: opts[:model],
       retries: opts[:invoke_retries] || 2,
       subscriber: subscriber,
       idle_timeout: opts[:idle_timeout],
       timeout_seconds: opts[:timeout_seconds],
       max_iterations: opts[:max_iterations],
       max_tokens: opts[:max_tokens],
       # Build the real client (which reads AWS creds) ONLY when no invoke_fun is injected.
       invoke_fun: opts[:invoke_fun] || default_invoke_fun(opts)
     }}
  end

  defp default_invoke_fun(opts) do
    client = opts[:client] || Client.new()
    fn inv -> Client.invoke_harness(client, inv) end
  end

  # Live event delivery: each decoded event is sent to the Session (the open/2
  # subscriber) as it arrives. Ordering vs the final {:turn, result} is guaranteed
  # because both originate in the same poll-turn task (FIFO per sender).
  defp live_forward(subscriber) when is_pid(subscriber),
    do: fn ev -> send(subscriber, {:provider_event, ev}) end

  defp live_forward(_), do: nil

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
    inv = %{
      harness_arn: conn.harness_arn,
      runtime_session_id: conn.sid,
      messages: messages,
      model: conn.model,
      idle_timeout: conn.idle_timeout,
      timeout_seconds: conn.timeout_seconds,
      max_iterations: conn.max_iterations,
      max_tokens: conn.max_tokens,
      on_event: live_forward(conn.subscriber)
    }

    case conn.invoke_fun.(inv) do
      {:ok, events} ->
        case stream_error(events) do
          {type, message} ->
            {:error, {:harness_stream_error, type, message}}

          nil ->
            cond do
              # A real terminal (messageStop carried a stop_reason) — surface the turn.
              normalize(events).stop_reason != nil -> {:ok, events, conn}
              # A truncated stream (no terminal) — retry, then surface as early_termination.
              retries_left > 0 -> invoke(conn, messages, retries_left - 1)
              true -> {:error, :early_termination}
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
    %{stop_reason: reason, tool_uses: tool_uses, text: text, usage: usage} =
      Converse.parse(events)

    custom =
      Enum.map(tool_uses, fn %{"toolUseId" => id, "name" => name, "input" => input} ->
        %ToolUse{id: id, name: name, input: input}
      end)

    %TurnResult{
      terminal: terminal(reason),
      stop_reason: reason,
      text: text,
      custom_tool_uses: custom,
      # Harness built-in tools execute in-microVM and do not surface a modelable event yet.
      server_tool_uses: [],
      usage: to_usage(usage),
      events: events
    }
  end

  defp to_usage(%{} = u),
    do: %Usage{
      input_tokens: u["inputTokens"] || 0,
      output_tokens: u["outputTokens"] || 0,
      raw: [u]
    }

  defp to_usage(_), do: nil

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
