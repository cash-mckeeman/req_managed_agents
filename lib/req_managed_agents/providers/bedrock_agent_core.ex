defmodule ReqManagedAgents.Providers.BedrockAgentCore do
  @moduledoc """
  `ReqManagedAgents.Provider` for the Bedrock AgentCore backend — `:request_response` mode.
  Each turn is one `InvokeHarness` call; resume re-sends the assistant `toolUse` + user
  `toolResult` delta (the harness does not persist the uncommitted tool-use turn). Composes
  the existing `AgentCore.{Client, Converse}` modules. Decoded events are additionally
  delivered live to the session as `{:provider_event, ev}` messages while a turn streams.
  `provision/2`'s `opts[:environment]` carries an `Environment.Spec` (or a map coerced via
  `Environment.Spec.new/1`, or `nil`). Its opaque `config` is handed to CreateHarness's
  `environment` field VERBATIM — no per-key indexing, symmetric with how
  `ClaudeManagedAgents` passes `config` straight to its wire body (filesystem mounts, custom
  containers, env vars, all opaque and never interpreted by this library). Environment is
  first-class (#70/#72): it reaches this provider only via `opts[:environment]`, never the
  spec, and its digest is folded into the harness name so different environments never
  collide on a name.
  """
  @behaviour ReqManagedAgents.Provider

  require Logger

  alias ReqManagedAgents.Agent.Spec
  alias ReqManagedAgents.AgentCore.{Client, Converse}
  alias ReqManagedAgents.Environment
  alias ReqManagedAgents.Providers.BedrockAgentCore.HarnessSpec
  alias ReqManagedAgents.Providers.BedrockAgentCore.HarnessStatus
  alias ReqManagedAgents.Providers.BedrockAgentCore.WaitBudget
  alias ReqManagedAgents.Providers.BedrockAgentCore.WaitContext
  alias ReqManagedAgents.Provisioner.Name
  alias ReqManagedAgents.Provisioner.Name.Policy
  alias ReqManagedAgents.{ToolUse, TurnResult, Usage}

  @impl true
  def mode, do: :request_response

  @doc """
  Provisions the harness for `spec`, waiting for it to reach READY.

  `opts[:timeout]` (ms) is the budget for the whole call, converted once here into
  a monotonic deadline that every wait shares — a provision that cannot finish
  returns a named error tuple strictly inside it rather than running past the
  deadline of whatever it runs under. The legacy `:ready_poll_ms` /
  `:ready_max_polls` pair is still accepted; see
  `ReqManagedAgents.Providers.BedrockAgentCore.WaitBudget` for how the two shapes
  relate.
  """
  @impl true
  def provision(spec, opts) do
    with {:ok, spec} <- Spec.new(spec),
         {:ok, harness_spec} <- build_spec(spec, opts),
         {:ok, budget} <- WaitBudget.new(opts) do
      do_provision(harness_spec, budget, opts)
    end
  end

  # Note: `build_spec/2` coerces `opts[:environment]` via `Environment.Spec.new/1` — a
  # single coercion point per provision that both threads env into the harness name and
  # sources the CreateHarness `environment` payload (env.config, verbatim) from it.

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
         environment: harness_environment(env)
       }}
    end
  end

  # `env.config` IS the verbatim CreateHarness `environment` payload — no per-key indexing,
  # symmetric with ClaudeManagedAgents' `env_config/1`. No environment, or an empty config,
  # → nil (drops the wire field), matching pre-#70's "no environment" behaviour.
  defp harness_environment(nil), do: nil
  defp harness_environment(%Environment.Spec{config: config}) when config == %{}, do: nil
  defp harness_environment(%Environment.Spec{config: config}), do: config

  defp validate_role_arn(arn) when is_binary(arn) do
    case String.trim(arn) do
      "" -> {:error, {:invalid_opts, :execution_role_arn}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_role_arn(_), do: {:error, {:invalid_opts, :execution_role_arn}}

  defp do_provision(harness_spec, budget, opts) do
    create_fun =
      opts[:create_fun] || fn s -> Client.create_harness(opts[:client] || Client.new(), s) end

    list_fun = opts[:list_fun] || fn -> Client.list_harnesses(poll_client(opts, budget)) end

    get_fun = opts[:get_fun] || fn hid -> Client.get_harness(poll_client(opts, budget), hid) end

    case create_fun.(harness_spec) do
      {:error, {:http_error, 409, _}} ->
        recover_existing(
          create_fun,
          harness_spec,
          list_fun,
          get_fun,
          harness_spec.name,
          budget,
          opts
        )

      created ->
        create_and_wait(created, get_fun, budget, opts)
    end
  end

  # One poll may spend only its share of what is left. Unbounded, a single hung
  # poll blocks for the client's full 600 s receive timeout — three times over,
  # since a control-plane call retries — so a wait's budget bounded nothing.
  #
  # Deliberately NOT applied to create, rollback or teardown. Rollback runs only
  # once the budget is spent, so bounding its DELETE by what remains would hand it
  # a 1 ms timeout and turn every timed-out provision into a leaked harness.
  #
  # The client is still built inside the closure: hoisting it would read AWS
  # credentials even when every seam is injected.
  defp poll_client(opts, budget) do
    client = opts[:client] || Client.new()

    bounded =
      WaitBudget.attempt_timeout(
        budget,
        client.receive_timeout,
        Client.control_plane_attempts()
      )

    %{client | receive_timeout: bounded}
  end

  defp create_and_wait(create_result, get_fun, budget, opts) do
    case normalize_create(create_result) do
      {:ok, arn, hid} ->
        ready_or_rollback(get_fun, arn, hid, budget, opts)

      {:error, reason} ->
        Logger.warning("agent_core CreateHarness did not yield a harness: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # CreateHarness returns the created resource wrapped under "harness" (verified live
  # against bedrock-agentcore-control), consistent with GetHarness — NOT a flat
  # "harnessArn". A 2xx body that does not carry BOTH an arn and a harnessId is drift,
  # not a handle: passing it on would let the provisioner cache a shape open/2 can
  # never use, and every later ensure/3 would serve the same poison from the store.
  defp normalize_create({:ok, %{"harness" => %{"arn" => arn, "harnessId" => hid}}})
       when is_binary(arn) and is_binary(hid),
       do: {:ok, arn, hid}

  defp normalize_create({:error, reason}), do: {:error, reason}
  defp normalize_create(other), do: {:error, {:unexpected_create_response, other}}

  # A harness this call created and could not bring to READY is a billable resource
  # nothing else will ever reclaim — the ready-wait's own failure is the last moment
  # its id is known. Rollback is best-effort and never replaces the original error.
  defp ready_or_rollback(get_fun, arn, hid, budget, opts) do
    case wait_until_ready(get_fun, hid, budget) do
      :ok ->
        {:ok, %{harness_arn: arn, harness_id: hid}}

      {:error, reason} ->
        rollback(hid, opts)
        {:error, reason}
    end
  catch
    # Any class that unwinds the stack — raise, throw, or exit — skips the case
    # above entirely, and the caller never receives a handle, so nothing else
    # knows the harness exists. `rescue` alone would miss two of the three: the
    # production get_fun runs through :telemetry.span, Req, Finch and NimblePool,
    # which re-raise the original class.
    #
    # This cannot cover a kill from OUTSIDE the process (an ExUnit timeout,
    # Process.exit/2 with :kill, VM death) — nothing in-process can, which is the
    # same limit §4.8 records against try/after. PR-4's prefix sweeper is the
    # compensating control for those.
    kind, reason ->
      rollback(hid, opts)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # Best-effort by contract: rollback must never replace the failure that caused
  # it, so a delete that errors, raises, or answers in an unexpected shape is
  # logged and swallowed.
  defp rollback(hid, opts) do
    delete_fun =
      opts[:delete_fun] || fn id -> Client.delete_harness(opts[:client] || Client.new(), id) end

    case delete_fun.(hid) do
      {:ok, _} ->
        Logger.info("agent_core rolled back harness #{hid} after a failed ready-wait")

      other ->
        Logger.warning(
          "agent_core could not roll back harness #{hid} " <>
            "(it may be orphaned): #{inspect(other)}"
        )
    end

    :ok
  catch
    kind, reason ->
      Logger.warning(
        "agent_core rollback of harness #{hid} failed hard " <>
          "(it may be orphaned): #{Exception.format_banner(kind, reason)}"
      )

      :ok
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
    base =
      [prefix, spec_name(spec)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("_")

    Name.compose(base, agent_digest(spec, env), Policy.agent_core())
  end

  # The spec name is part of the harness BASE, never the digest: `Agent.Spec.digest/1`
  # is shared across providers and deliberately excludes the name, so folding the name
  # into the digest here would rotate CMA names too.
  defp spec_name(%Spec{name: name}), do: name
  defp spec_name(%{name: name}) when is_binary(name), do: name
  defp spec_name(%{"name" => name}) when is_binary(name), do: name
  defp spec_name(_), do: nil

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

  defp recover_existing(create_fun, harness_spec, list_fun, get_fun, name, budget, opts) do
    case list_fun.() do
      {:ok, %{"harnesses" => harnesses}} ->
        cond do
          harness = recoverable_harness(harnesses, name) ->
            adopt(harness, get_fun, budget)

          deleting?(harnesses, name) ->
            # A prior same-name harness is still tearing down; wait it out, then
            # re-create. Both waits carry the SAME budget, so what the delete-wait
            # spends is gone from the ready-wait — they are one budget, not two.
            with :ok <- wait_until_deleted(list_fun, name, budget) do
              create_and_wait(create_fun.(harness_spec), get_fun, budget, opts)
            end

          true ->
            Logger.warning(
              "agent_core cannot recover harness #{name}: a same-name harness exists " <>
                "in a status that is neither reusable nor terminating"
            )

            {:error, {:harness_name_conflict, name}}
        end

      {:error, reason} ->
        Logger.warning("agent_core ListHarnesses failed during recovery: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.warning("agent_core ListHarnesses returned an unexpected shape: #{inspect(other)}")
        {:error, {:unexpected_list_response, other}}
    end
  end

  # An adopted harness was created by someone else, so a failed ready-wait here must
  # NOT delete it — rollback covers only what this call created.
  defp adopt(%{"arn" => arn, "harnessId" => hid}, get_fun, budget) do
    with :ok <- wait_until_ready(get_fun, hid, budget),
         do: {:ok, %{harness_arn: arn, harness_id: hid}}
  end

  defp adopt(harness, _get_fun, _budget) do
    Logger.warning("agent_core listing entry lacks an arn/harnessId: #{inspect(harness)}")
    {:error, {:unexpected_list_response, harness}}
  end

  defp recoverable_harness(harnesses, name) do
    Enum.find(harnesses, fn h ->
      h["harnessName"] == name and reusable?(h["status"])
    end)
  end

  # `:creating` is reusable on purpose: under content-addressing a harness carrying
  # this computed name IS this spec, so adopting one mid-create is what makes 409
  # recovery version-correct.
  defp reusable?(status) when is_binary(status),
    do: HarnessStatus.classify(status) in [:ready, :creating]

  # A listing entry with no status at all is unclassifiable, so it is neither
  # adopted nor waited on — previously it passed the not-in-blocklist check and
  # was adopted.
  defp reusable?(_), do: false

  defp deleting?(harnesses, name),
    do: Enum.any?(harnesses, &(&1["harnessName"] == name and terminating?(&1["status"])))

  defp terminating?(status) when is_binary(status),
    do: HarnessStatus.classify(status) == :terminating

  defp terminating?(_), do: false

  defp wait_until_deleted(list_fun, name, budget) do
    run_wait(:deleted, name, fn started ->
      deleted_loop(list_fun, name, budget, started, 0)
    end)
  end

  defp deleted_loop(list_fun, name, budget, started, poll_n) do
    case list_fun.() do
      {:ok, %{"harnesses" => hs}} ->
        n = poll_n + 1
        entry = Enum.find(hs, &(&1["harnessName"] == name))
        status = observed_status(entry)
        emit_poll(name, :deleted, status, started, n)

        cond do
          is_nil(entry) ->
            {:ok, n}

          WaitBudget.next(budget) == :poll ->
            sleep_and_recheck(list_fun, name, budget, started, n)

          true ->
            {{:error, {:harness_still_deleting, ctx(name, :deleted, status, started, n)}}, n}
        end

      # A listing failure mid-teardown is not evidence the harness survived; the
      # subsequent create is the real arbiter and 409s if it did. The wait still
      # ends without ever having seen it go, so say so — the stop line reports
      # :ok, which here means "stopped waiting", not "confirmed deleted".
      other ->
        Logger.warning(
          "agent_core delete-wait for #{name} could not list harnesses " <>
            "(proceeding unconfirmed; the next create arbitrates): #{inspect(other)}"
        )

        {:ok, poll_n}
    end
  end

  defp sleep_and_recheck(list_fun, name, budget, started, poll_n) do
    Process.sleep(budget.poll_ms)
    deleted_loop(list_fun, name, WaitBudget.spend(budget), started, poll_n)
  end

  # The status the listing actually returned. A harness whose delete failed sits
  # in DELETE_FAILED, not DELETING, and reporting the latter would misdirect the
  # next investigation; absent from the listing at all means gone.
  defp observed_status(nil), do: nil
  defp observed_status(entry), do: entry["status"]

  defp wait_until_ready(get_fun, hid, budget) do
    run_wait(:ready, hid, fn started ->
      ready_loop(get_fun, hid, budget, started, 0)
    end)
  end

  defp ready_loop(get_fun, hid, budget, started, poll_n) do
    case get_fun.(hid) do
      {:ok, %{"harness" => %{"status" => status}}} when is_binary(status) ->
        n = poll_n + 1
        emit_poll(hid, :ready, status, started, n)
        classified = HarnessStatus.classify(status)

        on_status(
          classified,
          {get_fun, hid, budget, WaitBudget.next(budget)},
          {started, n, status}
        )

      {:ok, other} ->
        {{:error, {:unexpected_get_harness_response, other}}, poll_n}

      {:error, reason} ->
        {{:error, reason}, poll_n}
    end
  end

  defp on_status(:ready, _poll, {_started, n, _status}), do: {:ok, n}

  defp on_status(:creating, {get_fun, hid, budget, :poll}, {started, n, _status}) do
    Process.sleep(budget.poll_ms)
    ready_loop(get_fun, hid, WaitBudget.spend(budget), started, n)
  end

  defp on_status(:creating, {_get_fun, hid, _budget, :expired}, {started, n, status}),
    do: {{:error, {:harness_ready_timeout, ctx(hid, :ready, status, started, n)}}, n}

  # A deleting harness can never become READY, so polling it is always wrong.
  defp on_status(:terminating, {_get_fun, hid, _budget, _verdict}, {started, n, status}),
    do: {{:error, {:harness_terminating, ctx(hid, :ready, status, started, n)}}, n}

  defp on_status({:failed, _}, {_get_fun, hid, _budget, _verdict}, {started, n, status}),
    do: {{:error, {:harness_failed, ctx(hid, :ready, status, started, n)}}, n}

  defp on_status({:unknown, _}, {_get_fun, hid, _budget, _verdict}, {started, n, status}),
    do: {{:error, {:harness_unknown_status, ctx(hid, :ready, status, started, n)}}, n}

  defp ctx(harness_id, phase, status, started, polls) do
    %WaitContext{
      harness_id: harness_id,
      phase: phase,
      last_status: status,
      elapsed_ms: elapsed(started),
      polls: polls
    }
  end

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started

  # ── instrumentation ──────────────────────────────────────────────────────────
  #
  # The bar is that the next canary failure is diagnosable from the run log
  # alone, so every poll logs as well as emitting telemetry — an attached
  # handler must not be a precondition for a readable failure.

  defp run_wait(phase, harness_id, loop) do
    started = System.monotonic_time(:millisecond)

    try do
      {result, polls} = loop.(started)
      emit_stop(harness_id, phase, started, polls, result)
      result
    catch
      kind, reason ->
        emit_exception(harness_id, phase, started, kind, reason)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp emit_poll(harness_id, phase, status, started, poll_n) do
    elapsed = elapsed(started)

    Logger.debug(fn ->
      "agent_core provision poll harness_id=#{harness_id} phase=#{phase} " <>
        "status=#{status || "absent"} poll_n=#{poll_n} elapsed_ms=#{elapsed}"
    end)

    :telemetry.execute(
      [:req_managed_agents, :agent_core, :provision, :poll],
      %{elapsed_ms: elapsed, poll_n: poll_n},
      %{harness_id: harness_id, status: status, phase: phase}
    )
  end

  defp emit_stop(harness_id, phase, started, polls, result) do
    duration = elapsed(started)
    tag = result_tag(result)

    # The one line worth keeping when a consumer runs above :debug — a failed
    # provision must not go quiet just because per-poll detail is filtered out.
    # It therefore has to carry last_status: that is the field that made 08-06
    # undiagnosable, and it lives nowhere else above :debug.
    log_stop(tag, fn ->
      "agent_core provision stop harness_id=#{harness_id} phase=#{phase} " <>
        "result=#{inspect(tag)} last_status=#{last_status(result) || "none"} " <>
        "polls=#{polls} duration_ms=#{duration}"
    end)

    :telemetry.execute(
      [:req_managed_agents, :agent_core, :provision, :stop],
      %{duration_ms: duration, polls: polls},
      %{harness_id: harness_id, phase: phase, result: tag}
    )
  end

  # The observed status is already inside the error's %WaitContext{}; a successful
  # wait ended on READY by definition.
  defp last_status(:ok), do: "READY"
  defp last_status({:error, {_tag, %WaitContext{last_status: status}}}), do: status
  defp last_status(_other), do: nil

  defp log_stop(:ok, message), do: Logger.info(message)
  defp log_stop(_error_tag, message), do: Logger.warning(message)

  defp emit_exception(harness_id, phase, started, kind, reason) do
    duration = elapsed(started)
    tag = exception_tag(kind, reason)

    Logger.warning(fn ->
      "agent_core provision failed hard harness_id=#{harness_id} phase=#{phase} " <>
        "kind=#{kind} error=#{Exception.format_banner(kind, reason)} duration_ms=#{duration}"
    end)

    :telemetry.execute(
      [:req_managed_agents, :agent_core, :provision, :exception],
      %{duration_ms: duration},
      %{harness_id: harness_id, phase: phase, kind: kind, result: {:exception, tag}}
    )
  end

  # A raised Elixir error is named by its struct; a throw or an exit has no
  # struct, so it is named by its class.
  defp exception_tag(:error, reason), do: Exception.normalize(:error, reason).__struct__
  defp exception_tag(kind, _reason), do: kind

  # The metadata carries the failure TAG, never the context struct: telemetry
  # metadata is fanned out to arbitrary handlers, and a stable atom is what a
  # metric can be grouped by.
  defp result_tag(:ok), do: :ok
  defp result_tag({:error, {tag, _ctx}}) when is_atom(tag), do: {:error, tag}
  defp result_tag({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp result_tag({:error, _reason}), do: {:error, :provider_error}

  # conn is a map keyed on harness_arn/sid/session_id/… — no live stream Task (request_response,
  # not streaming), so ref/consumer are always nil here; resumed? reflects a session_id: reattach.
  @impl true
  def session_id(conn), do: Map.get(conn, :session_id)

  @impl true
  def ref(_conn), do: nil

  @impl true
  def consumer(_conn), do: nil

  @impl true
  def resumed?(conn), do: Map.get(conn, :resume, false)

  @impl true
  def open(opts, subscriber) do
    # #80: RMA-canonical session_id: targets an EXISTING runtime session (reattach,
    # within AgentCore's session window); absent, the fresh path requires a
    # caller-minted :runtime_session_id exactly as before. When both are supplied,
    # session_id: wins and runtime_session_id: is ignored.
    sid = opts[:session_id] || Keyword.fetch!(opts, :runtime_session_id)

    {:ok,
     %{
       harness_arn: Keyword.fetch!(opts, :harness_arn),
       sid: sid,
       session_id: sid,
       resume: opts[:session_id] != nil,
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
