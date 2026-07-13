defmodule ReqManagedAgents.Providers.BedrockAgentCore do
  @moduledoc """
  `ReqManagedAgents.Provider` for the Bedrock AgentCore backend — `:request_response` mode.
  Each turn is one `InvokeHarness` call; resume re-sends the assistant `toolUse` + user
  `toolResult` delta (the harness does not persist the uncommitted tool-use turn). Composes
  the existing `AgentCore.{Client, Converse}` modules. Decoded events are additionally
  delivered live to the session as `{:provider_event, ev}` messages while a turn streams.
  `provision/2`'s `opts[:environment]` carries an `Environment.Spec` (or a map coerced via
  `Environment.Spec.new/1`, or `nil`). Its opaque `config` supplies the `environment`/
  `environment_variables` maps that pass through to CreateHarness verbatim (filesystem
  mounts, custom containers, env vars — never interpreted by this library). Environment is
  first-class (#70/#72): it reaches this provider only via `opts[:environment]`, never the
  spec, and its digest is folded into the harness name so different environments never
  collide on a name.
  """
  @behaviour ReqManagedAgents.Provider

  alias ReqManagedAgents.Agent.Spec
  alias ReqManagedAgents.AgentCore.{Client, Converse}
  alias ReqManagedAgents.Environment
  alias ReqManagedAgents.Providers.BedrockAgentCore.HarnessSpec
  alias ReqManagedAgents.{ToolUse, TurnResult, Usage}

  @impl true
  def mode, do: :request_response

  @ready_poll_ms 5_000
  @ready_max_polls 72
  @nonreusable_status ~w(DELETING DELETE_FAILED CREATE_FAILED UPDATE_FAILED)

  @impl true
  def provision(spec, opts) do
    with {:ok, spec} <- Spec.new(spec),
         {:ok, harness_spec} <- build_spec(spec, opts) do
      do_provision(harness_spec, opts)
    end
  end

  # Note: `build_spec/2` coerces `opts[:environment]` via `Environment.Spec.new/1` — a
  # single coercion point per provision that both threads env into the harness name and
  # sources the CreateHarness `environment`/`environment_variables` payload from it.

  @doc """
  Assembles the AgentCore harness-creation spec from an `Agent.Spec`-shaped
  `spec` map and provisioning `opts`. Validates `opts[:execution_role_arn]`
  BEFORE it ever reaches `CreateHarness` — a blank/missing value used to pass
  straight through (`Keyword.fetch!/2` only guards the key being absent, not a
  present-but-blank value) and surface as a cryptic AWS `HTTP 400 "Value null
  at 'executionRoleArn'"` (GitHub #64).
  """
  @spec build_spec(map(), keyword()) :: {:ok, HarnessSpec.t()} | {:error, term()}
  def build_spec(spec, opts) do
    with {:ok, role} <- validate_role_arn(opts[:execution_role_arn]),
         {:ok, env} <- Environment.Spec.new(opts[:environment]) do
      {:ok,
       %HarnessSpec{
         name: harness_name(spec, opts[:name_prefix], env),
         execution_role_arn: role,
         system_prompt: spec.system_prompt,
         model: spec.model_config,
         tools: spec.tools,
         environment: env_field(env, :environment),
         environment_variables: env_field(env, :environment_variables)
       }}
    end
  end

  # The opaque, provider-verbatim CreateHarness payload lives under the environment's
  # `config`: `:environment` / `:environment_variables` map straight onto the two HarnessSpec
  # fields (byte-identical wire body to the pre-#72 opts-carried values). No environment → both nil.
  defp env_field(nil, _key), do: nil
  defp env_field(%Environment.Spec{config: config}, key), do: Map.get(config, key)

  defp validate_role_arn(arn) when is_binary(arn) do
    case String.trim(arn) do
      "" -> {:error, {:invalid_opts, :execution_role_arn}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_role_arn(_), do: {:error, {:invalid_opts, :execution_role_arn}}

  defp do_provision(harness_spec, opts) do
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
        recover_existing(
          create_fun,
          harness_spec,
          list_fun,
          get_fun,
          harness_spec.name,
          poll_ms,
          max_polls
        )

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
  def harness_name(spec, prefix, env \\ nil) do
    [prefix, "harness_#{agent_digest(spec, env)}"] |> Enum.reject(&is_nil/1) |> Enum.join("_")
  end

  # The harness content-address is a two-layer fold (#70/#72):
  #
  #   * No environment → `Agent.Spec.digest/1` over the identity fields it covers
  #     (system_prompt/tools/terminal_tool/model_config). This is byte-identical to the
  #     pre-0.7.0 env-less digest, so env-less harnesses keep their names across the upgrade.
  #   * An `Environment.Spec` → the same agent digest folded with `Environment.Spec.digest/1`.
  #     Two provisions of the same `Agent.Spec` into different environments now produce
  #     different harness names (the collision fix); env-bearing harnesses re-provision once
  #     on upgrade (documented migration).
  #
  # Environment reaches this function only via `env` — never off the spec (`Agent.Spec` has
  # no environment field), so there is no spec-embedded fallback branch to worry about.
  defp agent_digest(spec, nil), do: Spec.digest(coerce_spec(spec))

  defp agent_digest(spec, %Environment.Spec{} = env) do
    {Spec.digest(coerce_spec(spec)), Environment.Spec.digest(env)}
    |> ReqManagedAgents.Provisioner.hash()
    |> binary_part(0, 8)
    |> String.downcase()
  end

  defp coerce_spec(%Spec{} = spec), do: spec

  defp coerce_spec(spec) do
    {:ok, s} = Spec.new(Map.put_new(spec, :name, "harness"))
    s
  end

  defp recover_existing(create_fun, harness_spec, list_fun, get_fun, name, poll_ms, max_polls) do
    case list_fun.() do
      {:ok, %{"harnesses" => harnesses}} ->
        cond do
          harness = recoverable_harness(harnesses, name) ->
            case harness do
              %{"arn" => arn, "harnessId" => hid} ->
                with :ok <- wait_until_ready(get_fun, hid, poll_ms, max_polls),
                     do: {:ok, %{harness_arn: arn, harness_id: hid}}

              _ ->
                {:error, {:unexpected_list_response, harness}}
            end

          deleting?(harnesses, name) ->
            # A prior same-name harness is still tearing down; wait it out, then re-create.
            with :ok <- wait_until_deleted(list_fun, name, poll_ms, max_polls),
                 {:ok, %{"harness" => %{"arn" => arn, "harnessId" => hid}}} <-
                   create_fun.(harness_spec),
                 :ok <- wait_until_ready(get_fun, hid, poll_ms, max_polls) do
              {:ok, %{harness_arn: arn, harness_id: hid}}
            end

          true ->
            {:error, {:harness_name_conflict, name}}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_list_response, other}}
    end
  end

  defp recoverable_harness(harnesses, name) do
    Enum.find(harnesses, fn h ->
      h["harnessName"] == name and h["status"] not in @nonreusable_status
    end)
  end

  defp deleting?(harnesses, name),
    do: Enum.any?(harnesses, &(&1["harnessName"] == name and &1["status"] == "DELETING"))

  defp wait_until_deleted(list_fun, name, poll_ms, max_polls, polls \\ 0)

  defp wait_until_deleted(_list_fun, name, _poll_ms, max_polls, polls) when polls >= max_polls,
    do: {:error, {:harness_still_deleting, name}}

  defp wait_until_deleted(list_fun, name, poll_ms, max_polls, polls) do
    case list_fun.() do
      {:ok, %{"harnesses" => hs}} ->
        if Enum.any?(hs, &(&1["harnessName"] == name)) do
          Process.sleep(poll_ms)
          wait_until_deleted(list_fun, name, poll_ms, max_polls, polls + 1)
        else
          :ok
        end

      _ ->
        :ok
    end
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
      Enum.map(custom_tool_uses, fn %ToolUse{id: id, name: name, input: input} ->
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
  def text_delta(%{"contentBlockDelta" => %{"delta" => %{"text" => t}}}) when is_binary(t), do: t
  def text_delta(_), do: nil

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
