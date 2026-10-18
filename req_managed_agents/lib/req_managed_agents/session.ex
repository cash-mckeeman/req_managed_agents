defmodule ReqManagedAgents.Session do
  @moduledoc """
  The one agent loop, provider- and transport-agnostic.

  A `Session` drives any `ReqManagedAgents.Provider` to completion: invoke a turn → normalize →
  run the return-of-control tools locally via the `:handler` → resume → repeat until a terminal.
  The loop host runs the agent loop — a managed provider server-side, or
  `ReqManagedAgents.Providers.Local` in-process. The provider's `mode/0` (`:streaming` push or
  `:request_response` pull) only changes how a turn's events are *acquired*; the loop, the result
  shape, and the raw-event passthrough are identical across providers.

  Pick a provider — `ReqManagedAgents.Providers.ClaudeManagedAgents` (streaming),
  `ReqManagedAgents.Providers.BedrockAgentCore` (request/response), or
  `ReqManagedAgents.Providers.Local` (in-process) — and:

      # synchronous run-to-completion
      {:ok, %ReqManagedAgents.SessionResult{terminal: t, stop_reason: r, events: raw}} =
        ReqManagedAgents.Session.run(provider, handler: MyTools, prompt: "Hi", ...)

      # live, long-lived (stays alive after a terminal; `:notify` gets {:managed_agents_session, %ReqManagedAgents.SessionResult{}})
      {:ok, pid} = ReqManagedAgents.Session.start_link(provider, handler: MyTools, notify: self(), ...)
      ReqManagedAgents.Session.message(pid, "follow-up")

  `:evidence_recorder` accepts a caller-owned `ReqManagedAgents.Evidence.Recorder` pid
  for Claude Managed Agents or AgentCore observations. The caller snapshots and stops it;
  recorder loss does not change the session result or retry policy.

  Required opts: `:handler` (a `ReqManagedAgents.Handler` module or a 3-arity fn). Optional:
  `:context`, `:prompt`, `:outcome` (a `%ReqManagedAgents.Outcome{}` or a map with the same keys
  `%{description:, rubric:, max_iterations:}` — kicks off a
  `user.define_outcome` graded session instead of a `user.message`; mutually exclusive with
  `:prompt`, outcome wins; `{:error, :outcome_unsupported}` on providers without native support),
  `:budget` (a `%ReqManagedAgents.Budget{}` or a map with the same keys — a provider-enforced
  spending cap on a fresh Claude Managed Agents session, confirmed by the provider before any
  prompt is sent; see `ReqManagedAgents.Budget`; `{:error, :budget_unsupported}` on other
  providers, an error alongside `:session_id`),
  `:timeout`, `:max_turns`, `:notify`, `:name`, `:telemetry_metadata`,
  `:turn_guard` (a 1-arity fun invoked after each turn's usage accumulation with
  `%{usage: %ReqManagedAgents.Usage{}, turns: n, session_id: id}`, returning `:cont` or `{:halt, reason}`;
  on halt the run stops with `{:error, {:halted, reason}}` and a `:terminated` result is
  notified — usage/turns accumulate within the current request, the same scope as `:max_turns`;
  the guard runs *before* the `max_turns` check and wins when both would trip on the same turn;
  it fires on terminal-tool re-prompt turns, whose `turns` counter keeps incrementing normally;
  guards must not raise — a raising guard crashes the session and surfaces as
  `{:error, {exception, stack}}` to `run/2` rather than producing a `{:halt, …}`),
  `:require_terminal_tool` + `:terminal_tool` + `:max_reprompts` (default 2): an `:end_turn`
  that never called `terminal_tool` is re-driven with a re-prompt; exhausted re-prompts finish
  with `stop_reason: :no_terminal_tool`. Re-prompt turns count against `:max_turns`.
  For long AgentCore runs set `:timeout` (the end-to-end run budget, default 600_000 ms)
  at or above the server-side budget — a `run/2` timeout returns `{:error, :timeout}` and
  tears down the in-flight invoke client-side (the poll task and its HTTP stream are shut
  down). The server may still run the already-received invocation to its own limit: the
  server-side `timeoutSeconds` remains the authoritative server budget.
  Transport liveness is guarded per turn by `:idle_timeout` and total
  cost by the `:timeout_seconds`/`:max_iterations`/`:max_tokens` per-invocation overrides
  (Bedrock AgentCore only).
  `:model_config` (a `%ReqManagedAgents.ModelConfig{}`, or a map or keyword list with its
  keys) carries the run's model, the provider's credential and destination, and
  correlation `:metadata`. It is validated at start (`{:error, {:invalid_opts,
  {:model_config, reason}}}`). A `:model` the provider cannot apply returns
  `{:error, :runtime_model_unsupported}`, and an `:api_key`, `:bearer_token_file` or
  `:base_url` it cannot use returns `{:error, :data_plane_unsupported}`; see
  `ReqManagedAgents.Provider.supports?/2`.

  `run/2` also accepts `:deadline`, an absolute `System.monotonic_time(:millisecond)`
  value bounding local initialization, execution waits and owned-process teardown.
  Caller death terminates the session and owned workers. Without `:deadline`,
  `:timeout` starts after initialization.

  After a successful open is acknowledged, `:notify` receives one
  `{:managed_agents_session, result}` per request, including local errors, before
  `run/2` returns. Error results retain accepted usage/events with
  `terminal: :terminated`; synchronous error tuples are unchanged. Failed or
  interrupted initialization has no fabricated result and may still have
  contacted the provider. See `ReqManagedAgents.SessionResult.in_flight`.

  Provider-specific opts (e.g. `:agent_id`/`:environment_id`, `:harness_arn`/`:runtime_session_id`,
  `:session_id` to resume) are forwarded to the provider's `open/2`. `:agent`/`:environment` accept
  the handle returned by `ReqManagedAgents.ensure_agent/3` / `ensure_environment/3`
  (a `%ReqManagedAgents.Agent.Handle{}` / `%ReqManagedAgents.Provisioner.Environment.Handle{}`, or a
  bare map with the same `agent_id:`/`environment_id:` keys) — the handle is unpacked to
  `:agent_id`/`:environment_id` before `open/2` runs, so callers pass the handle instead of
  hand-threading the raw id; an explicit `:agent_id`/`:environment_id` wins if both are given.
  """
  use GenServer
  require Logger

  alias ReqManagedAgents.{
    ModelConfig,
    Outcome,
    Provider,
    Session.State,
    SessionInfo,
    SessionResult,
    Tools,
    ToolUse,
    TurnResult,
    Usage
  }

  alias ReqManagedAgents.Evidence.Recorder
  alias ReqManagedAgents.Session.Completion
  alias ReqManagedAgents.Session.Completion.Request

  @max_tool_concurrency 8

  @spec run(module(), keyword()) :: {:ok, ReqManagedAgents.SessionResult.t()} | {:error, term()}
  def run(provider, opts) do
    with :ok <- validate_deadline(opts),
         {:ok, owner} <-
           Completion.start(caller: self(), notify: opts[:notify], deadline: opts[:deadline]) do
      monitor = Process.monitor(owner)
      opts = completion_opts(opts, owner) |> Keyword.put(:caller, self())

      try do
        case GenServer.start(__MODULE__, {provider, opts}, start_options(opts)) do
          {:ok, _pid} ->
            unless opts[:deadline], do: Completion.arm_timeout(owner, opts[:timeout] || 600_000)

          {:error, reason} ->
            Completion.abort(owner, reason)
        end

        await_completion(owner, monitor)
      after
        Completion.abort(owner, :shutdown)
        Process.demonitor(monitor, [:flush])
      end
    end
  end

  defp await_completion(owner, monitor) do
    receive do
      {:session_completion, ^owner, result} -> result
      {:DOWN, ^monitor, :process, ^owner, reason} -> {:error, reason}
    end
  end

  defp validate_deadline(opts) do
    case Keyword.fetch(opts, :deadline) do
      :error ->
        :ok

      {:ok, deadline} when is_integer(deadline) ->
        if remaining(deadline) == 0, do: {:error, :timeout}, else: :ok

      {:ok, _invalid} ->
        {:error, {:invalid_opts, :deadline}}
    end
  end

  defp completion_opts(opts, owner) do
    opts
    |> Keyword.put(:completion_owner, owner)
    |> Keyword.put(:deadline_own_worker, fn -> own_process(owner, :worker, self()) end)
  end

  defp start_options(opts) do
    if opts[:deadline], do: [timeout: remaining(opts[:deadline])], else: []
  end

  defp own_deadline_process(opts, kind, pid) when is_pid(pid) do
    kind = if kind == :own_session, do: :session, else: :worker
    own_process(opts[:completion_owner], kind, pid)
  end

  defp own_deadline_process(_opts, _kind, _pid), do: :ok

  defp own_process(owner, kind, pid) do
    result =
      case kind do
        :session -> Completion.register_session(owner, pid)
        :worker -> Completion.register_worker(owner, pid)
      end

    completion_ack(result)
  end

  defp completion_ack(:ok), do: :ok
  defp completion_ack({:error, :closed}), do: exit(:normal)
  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  @doc "Start a long-lived session. Unlike run/2, it stays alive after a terminal for follow-ups."
  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(provider, opts) do
    with :ok <- validate_deadline(opts),
         {:ok, owner} <-
           Completion.start(
             caller: self(),
             reply_to: nil,
             notify: opts[:notify],
             deadline: opts[:deadline]
           ) do
      opts = completion_opts(opts, owner)

      case GenServer.start_link(
             __MODULE__,
             {provider, opts},
             [name: opts[:name]] ++ start_options(opts)
           ) do
        {:ok, _pid} = ok ->
          ok

        {:error, reason} = error ->
          Completion.abort(owner, reason)
          error
      end
    end
  end

  @doc "Return a child_spec for a live session."
  def child_spec({provider, opts}) do
    %{
      id: opts[:name] || __MODULE__,
      start: {__MODULE__, :start_link, [provider, opts]},
      restart: :transient
    }
  end

  @doc "Send a follow-up user message into a running live session."
  @spec message(pid(), String.t()) :: :ok
  def message(pid, text), do: GenServer.cast(pid, {:message, text})

  @doc """
  Post a pre-built raw user event (e.g. `Event.tool_confirmation/2`, a mid-session
  `Event.define_outcome/3`) into a running live session. The event is pushed verbatim —
  no turn accounting or accumulator reset. Streaming providers only:
  `{:error, :unsupported}` on `:request_response` providers (their input is consumed
  by `poll_turn/2`, there is no out-of-band channel).
  """
  @spec send_event(pid(), map()) :: :ok | {:error, term()}
  def send_event(pid, %{} = event), do: GenServer.call(pid, {:send_event, event})

  @impl true
  def init({provider, opts}) do
    # Trap exits so a crash in the linked stream-consumer / poll-turn Task arrives as {:EXIT,…}
    # (driving reconnect or a surfaced error) instead of killing this process and its caller.
    Process.flag(:trap_exit, true)
    own_deadline_process(opts, :own_session, self())

    with {:ok, opts} <- coerce_model_config(opts),
         :ok <- validate_opts(provider, opts),
         {:ok, opts} <- native_model_config(provider, opts) do
      open_session(provider, opts)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # ModelConfig is parsed before these start-time checks so capability validation
  # cannot silently miss keys in the caller's input shape.
  defp validate_opts(provider, opts) do
    cond do
      not valid_turn_guard?(opts[:turn_guard]) ->
        {:error, {:invalid_turn_guard, opts[:turn_guard]}}

      opts[:require_terminal_tool] && not is_binary(opts[:terminal_tool]) ->
        {:error, {:invalid_opts, :terminal_tool_required}}

      opts[:outcome] != nil and not valid_outcome?(opts[:outcome]) ->
        {:error, {:invalid_opts, :outcome}}

      true ->
        validate_supported(provider, opts)
    end
  end

  @start_requirements [
    {:outcome, :outcome_unsupported},
    {:budget, :budget_unsupported},
    {:runtime_model, :runtime_model_unsupported},
    {:data_plane, :data_plane_unsupported},
    {:bearer_token_file, :data_plane_unsupported}
  ]

  defp validate_supported(provider, opts) do
    requested = requested_options(opts)

    Enum.find_value(@start_requirements, :ok, fn {option, refusal} ->
      if option in requested and not applies?(provider, option), do: {:error, refusal}
    end)
  end

  defp applies?(provider, :outcome), do: Provider.supports?(provider, :outcomes)
  defp applies?(provider, :budget), do: Provider.supports?(provider, :budget)
  defp applies?(provider, :runtime_model), do: Provider.supports?(provider, :runtime_model)
  defp applies?(provider, :data_plane), do: Provider.supports?(provider, :data_plane)
  # A bearer-token file authenticates a managed-agents API client; a chat-completions
  # wire takes an api_key, so the file would be silently dropped there.
  defp applies?(provider, :bearer_token_file),
    do: Provider.data_plane(provider) == :managed_agents_api

  defp requested_options(opts) do
    config = opts[:model_config]

    for {option, true} <- [
          outcome: opts[:outcome] != nil,
          budget: opts[:budget] != nil,
          runtime_model: match?(%ModelConfig{model: model} when model != nil, config),
          data_plane: match?(%ModelConfig{}, config) and ModelConfig.data_plane?(config),
          bearer_token_file:
            match?(%ModelConfig{bearer_token_file: file} when file != nil, config)
        ],
        do: option
  end

  defp coerce_model_config(opts) do
    case opts[:model_config] do
      nil ->
        {:ok, opts}

      value ->
        case ModelConfig.new(value) do
          {:ok, config} -> {:ok, Keyword.put(opts, :model_config, config)}
          {:error, reason} -> {:error, {:invalid_opts, {:model_config, reason}}}
        end
    end
  end

  # Translate only after capability validation: providers must refuse a model they
  # cannot apply before attempting to interpret its catalog id.
  defp native_model_config(provider, opts) do
    case opts[:model_config] do
      %ModelConfig{model: model} = config when is_binary(model) ->
        case Provider.native_model(provider, model) do
          {:ok, native} -> {:ok, Keyword.put(opts, :model_config, %{config | model: native})}
          {:error, reason} -> {:error, {:invalid_opts, {:model_config, reason}}}
        end

      _no_catalog_model ->
        {:ok, opts}
    end
  end

  defp canonical_model_config(opts) do
    case opts[:model_config] do
      %ModelConfig{} = config -> Keyword.put(opts, :model_config, ModelConfig.to_map(config))
      _absent_or_canonical -> opts
    end
  end

  defp valid_outcome?(outcome), do: match?({:ok, _}, Outcome.new(outcome))

  defp valid_turn_guard?(nil), do: true
  defp valid_turn_guard?(guard), do: is_function(guard, 1)

  defp open_session(provider, opts) do
    opts =
      opts
      |> lift_handles()
      |> canonical_model_config()

    evidence = Recorder.begin(opts[:evidence_recorder], provider)
    opts = evidence_opts(opts, evidence)

    case observed_open(provider, opts, evidence) do
      {:ok, conn} ->
        own_deadline_process(opts, :own_worker, provider.consumer(conn))
        evidence_context(evidence, provider, conn)

        meta =
          Map.merge(
            opts[:telemetry_metadata] || %{},
            model_config_metadata(opts)
          )

        state = %State{
          provider: provider,
          evidence: evidence,
          delta?: exports_text_delta?(provider),
          mode: provider.mode(),
          conn: conn,
          info: build_info(provider, conn, meta),
          opts: opts,
          handler: Keyword.fetch!(opts, :handler),
          context: opts[:context],
          caller: opts[:caller],
          meta: meta,
          ref: provider.ref(conn),
          consumer: provider.consumer(conn),
          poll_task: nil,
          kicked_off: false,
          seen: MapSet.new(),
          reconnect_attempts: 0,
          events: [],
          turn_events: [],
          live_forwarded: 0,
          turns: 0,
          max_turns: opts[:max_turns] || 50,
          custom_tool_uses: [],
          server_tool_uses: [],
          usage: Usage.zero(),
          turn_guard: opts[:turn_guard],
          enforced_terminal_tool: if(opts[:require_terminal_tool], do: opts[:terminal_tool]),
          max_reprompts: opts[:max_reprompts] || 2,
          reprompts_left: opts[:max_reprompts] || 2,
          # A resume (session_id set) that also carries :prompt delivers it as a user.message
          # once reconnect/3 consolidates to idle with nothing pending (see handle_info(:reconnect,
          # …) below) — the reattach seam (#66). Gated on resumed?/1 (see pending_user_message/2):
          # a fresh (non-resume) session must NOT arm this, or a later live reconnect (e.g. after a
          # post-kickoff stream drop) would reach the same idle branch and redeliver the kickoff
          # prompt as a spurious second user.message.
          pending_user_message: pending_user_message(provider, conn, opts)
        }

        state = begin_request(state)
        {:ok, state, {:continue, if(provider.resumed?(conn), do: :resume, else: :maybe_kickoff)}}

      # Surface the provider's error verbatim (e.g. {:create_session_failed, _}) — no extra wrapping.
      {:error, reason} ->
        Recorder.observe(evidence, :invocation_end, result: :error, error_code: "open_failed")
        {:stop, reason}
    end
  end

  defp evidence_opts(opts, nil), do: opts
  defp evidence_opts(opts, evidence), do: Keyword.put(opts, :evidence_context, evidence)

  defp evidence_context(nil, _provider, _conn), do: :ok

  defp evidence_context(evidence, provider, conn),
    do:
      Recorder.context(evidence.recorder, evidence_provider(provider), provider.session_id(conn))

  defp observed_open(provider, opts, evidence) do
    provider.open(opts, self())
  catch
    kind, reason ->
      Recorder.observe(evidence, :invocation_end, result: :error, error_code: "open_failed")
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp evidence_provider(ReqManagedAgents.Providers.BedrockAgentCore), do: :agentcore
  defp evidence_provider(_), do: :managed

  # Only a resume arms pending_user_message — see the state-build comment above (#66).
  defp pending_user_message(provider, conn, opts),
    do: if(provider.resumed?(conn), do: opts[:prompt])

  # Managed-entity handles (from ensure_agent/3, ensure_environment/3) unpack to
  # the raw ids providers' open/2 read — callers pass the handle, not the id.
  # An explicit :agent_id / :environment_id wins if both are present.
  defp lift_handles(opts) do
    opts
    |> lift_handle(:agent, :agent_id)
    |> lift_handle(:environment, :environment_id)
  end

  defp lift_handle(opts, handle_key, id_key) do
    case {opts[id_key], opts[handle_key]} do
      {nil, h} when is_map(h) ->
        Keyword.put(opts, id_key, Map.get(h, id_key) || Map.get(h, to_string(id_key)))

      _ ->
        opts
    end
  end

  # request_response kicks off immediately; streaming waits for the stream's :connected.
  @impl true
  def handle_continue(:maybe_kickoff, %{mode: :request_response} = s), do: kickoff(s)
  def handle_continue(:maybe_kickoff, s), do: {:noreply, s}

  # Resuming an existing session: consolidate (reconnect/3) instead of kicking off. Mark
  # kicked_off so the reconnected stream's :connected does not fire a spurious kickoff.
  def handle_continue(:resume, s) do
    send(self(), :reconnect)
    {:noreply, %{s | kicked_off: :resuming}}
  end

  def handle_continue(:next_message, s) do
    [text | rest] = s.request.pending_messages
    s = %{s | request: %{s.request | pending_messages: rest}}
    start_message(s, text)
  end

  @impl true
  def handle_info({:managed_agents, ref, :connected}, %{ref: ref, kicked_off: false} = s),
    do: kickoff(s)

  def handle_info({:managed_agents, ref, :connected}, %{ref: ref} = s), do: {:noreply, s}

  def handle_info(
        {:managed_agents, ref, {:event, ev}},
        %State{ref: ref, request: %Request{generation: nil}} = s
      ) do
    Recorder.native(native_evidence(s), ev)
    id = ev["id"]

    if is_binary(id) and MapSet.member?(s.seen, id) do
      {:noreply, s}
    else
      forward_with_delta(s, ev)
      seen = if is_binary(id), do: MapSet.put(s.seen, id), else: s.seen
      {:noreply, %{s | seen: seen}}
    end
  end

  def handle_info({:managed_agents, ref, {:event, ev}}, %{ref: ref} = s) do
    Recorder.native(native_evidence(s), ev)
    id = ev["id"]

    if is_binary(id) and MapSet.member?(s.seen, id) do
      # Already processed (re-delivered after a reconnect) — skip.
      {:noreply, s}
    else
      s = %{
        s
        | seen: if(is_binary(id), do: MapSet.put(s.seen, id), else: s.seen),
          turn_events: s.turn_events ++ [ev]
      }

      s = checkpoint_partial(s)
      forward_with_delta(s, ev)
      if s.provider.turn_boundary?(ev), do: handle_turn(s, s.turn_events), else: {:noreply, s}
    end
  end

  def handle_info({:managed_agents, ref, :done}, %{ref: ref} = s), do: {:noreply, s}

  # A LIVE streaming session (no synchronous caller) reconnects-with-consolidation on a stream
  # drop; a synchronous run/2 surfaces the error instead.
  def handle_info({:managed_agents, ref, {:error, _reason}}, %{ref: ref, caller: nil} = s) do
    s = stream_failed(s)
    Process.send_after(self(), :reconnect, backoff_ms(s))
    {:noreply, %{s | reconnect_attempts: s.reconnect_attempts + 1}}
  end

  def handle_info({:managed_agents, ref, {:error, reason}}, %{ref: ref} = s),
    do: stop_error(s, reason)

  def handle_info(:reconnect, s) do
    s = mark_in_flight(s)
    s = prepare_reconnect_evidence(s)

    case safe_reconnect(s) do
      {:ok, conn, pending, seen, recovered} ->
        own_deadline_process(s.opts, :own_worker, s.provider.consumer(conn))

        # reconnect_attempts is NOT reset here — only a real terminal (finish/2) resets it — so a
        # connect→drop flap actually escalates the backoff instead of hammering at 500ms.
        resuming? = s.kicked_off == :resuming

        s = %{
          s
          | conn: conn,
            info: build_info(s.provider, conn, s.meta),
            ref: s.provider.ref(conn),
            consumer: s.provider.consumer(conn),
            seen: seen,
            kicked_off: true
        }

        cond do
          pending != [] ->
            redrive(s, pending)

          # Idle, nothing unanswered: this is the reattach seam (#66) — a resume that also
          # carries a new :prompt delivers it now, as a fresh user.message, via the same send
          # path a live follow-up (:message) uses. No prompt → unchanged: park (today's
          # behavior for a genuinely idle resume). Reset turns/accumulators exactly like a
          # live follow-up (handle_cast({:message, …})) does — a delivered message starts a
          # fresh request, so it must not inherit turns/usage accumulated by an earlier
          # pending-tool-use redrive on the same resume, or max_turns can trip early.
          s.pending_user_message ->
            deliver_pending_message(s)

          resuming? ->
            {:noreply, s}

          true ->
            recover_events(s, recovered)
        end

      # A sync run/2 surfaces a list/reconnect failure; a live session backs off and retries.
      {:error, reason} ->
        if s.caller do
          reply(s, {:error, reason})
        else
          Recorder.observe(evidence_attempt(s), :retry, error_code: Recorder.code(reason))
          s = retire_attempt(s)
          Process.send_after(self(), :reconnect, backoff_ms(s))
          {:noreply, %{s | reconnect_attempts: s.reconnect_attempts + 1}}
        end
    end
  end

  # Live event from a request_response provider mid-turn (e.g. BedrockAgentCore
  # streaming): forward to the handler and telemetry NOW; the {:turn, …} that
  # follows (FIFO from the same poll-turn task) then skips batch forwarding.
  # Handler delivery is at-least-once across retried attempts — the canonical
  # exactly-once record is TurnResult/SessionResult.events.
  def handle_info({:provider_event, ev}, s) do
    forward_with_delta(s, ev)

    :telemetry.execute(
      [:req_managed_agents, :stream, :event],
      %{},
      Map.merge(s.meta, %{type: envelope_type(ev)})
    )

    {:noreply, %{s | live_forwarded: s.live_forwarded + 1}}
  end

  def handle_info(
        {:turn, generation, {:ok, events, conn}},
        %State{request: %Request{generation: generation}} = s
      ) do
    # Batch forwarding only when nothing was live-forwarded this turn (a live
    # provider already delivered each event as it arrived).
    if s.live_forwarded == 0, do: Enum.each(events, &forward_with_delta(s, &1))
    handle_turn(%{s | conn: conn, live_forwarded: 0, poll_task: nil}, events)
  end

  def handle_info(
        {:turn, generation, {:error, reason}},
        %State{request: %Request{generation: generation}} = s
      ),
      do: stop_error(s, reason)

  # Linked-Task exits: a clean exit is fine; an abnormal consumer-task crash drives reconnect
  # (live) or surfaces an error (sync); any other linked exit (parent/supervisor) stops us.
  def handle_info({:EXIT, _pid, :normal}, s), do: {:noreply, s}

  def handle_info({:EXIT, pid, _reason}, %{consumer: pid, caller: nil} = s) do
    s = stream_failed(s)
    Process.send_after(self(), :reconnect, backoff_ms(s))
    {:noreply, %{s | reconnect_attempts: s.reconnect_attempts + 1}}
  end

  def handle_info({:EXIT, pid, reason}, %{consumer: pid} = s), do: stop_error(s, reason)
  def handle_info({:EXIT, _pid, reason}, s), do: {:stop, reason, s}

  def handle_info({:poll_task_failed, task, reason}, %State{poll_task: task} = s)
      when is_pid(task),
      do: {:stop, reason, s}

  def handle_info(_other, s), do: {:noreply, s}

  @impl true
  def handle_call({:send_event, event}, _from, %{mode: :streaming} = s) do
    started? = is_nil(s.request.generation)
    s = if started?, do: begin_request(s, s.request.snapshot), else: s
    s = begin_work(s)

    case s.provider.push_input(s.conn, [event]) do
      {:error, reason} = result when started? ->
        case live_push_error(s, reason) do
          {:noreply, s} -> {:reply, result, s}
          {:noreply, s, next} -> {:reply, result, s, next}
        end

      result ->
        {:reply, result, s}
    end
  end

  def handle_call({:send_event, _event}, _from, s), do: {:reply, {:error, :unsupported}, s}

  @impl true
  # A follow-up message starts a fresh request: reset the per-request turn counter and accumulators
  # so max_turns bounds a runaway tool loop within one request, not the session's whole lifetime.
  def handle_cast({:message, text}, %State{request: %Request{generation: generation}} = s)
      when is_reference(generation) do
    request = %{s.request | pending_messages: s.request.pending_messages ++ [text]}
    {:noreply, %{s | request: request}}
  end

  def handle_cast({:message, text}, s), do: start_message(s, text)

  defp start_message(s, text),
    do: deliver_user_message(begin_request(reset_acc(%{s | turns: 0})), text)

  @impl true
  # Linked workers ignore a normal exit; ordinary Session shutdown must reap them too.
  def terminate(_reason, s) do
    shutdown(s.poll_task)
    shutdown(s.consumer)
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, _state} -> {:state, :redacted}
      {:message, _message} -> {:message, :redacted}
      {:log, _log} -> {:log, []}
      {:reason, _reason} -> {:reason, :redacted}
      entry -> entry
    end)
  end

  # Killing an already-dead pid is a harmless no-op — no liveness check needed.
  defp shutdown(pid) when is_pid(pid), do: Process.exit(pid, :kill)
  defp shutdown(_other), do: :ok

  defp reset_acc(s),
    do: %{
      s
      | events: [],
        custom_tool_uses: [],
        server_tool_uses: [],
        reprompts_left: s.max_reprompts,
        usage: Usage.zero()
    }

  defp kickoff(s) do
    s = begin_work(%{s | kicked_off: true})
    drive(s, s.provider.kickoff_input(s.opts))
  end

  # The one send path for a plain user-text turn: build the provider's user.message input and
  # drive a fresh turn with it. Shared by a live follow-up (handle_cast {:message, …}) and a
  # resume that carries a new :prompt (handle_info(:reconnect, …) — issue #66) — one send path,
  # not two copies.
  defp deliver_pending_message(s) do
    text = s.pending_user_message
    s = reset_acc(%{s | turns: 0, pending_user_message: nil})
    s = if is_nil(s.request.generation), do: begin_request(s), else: s
    deliver_user_message(s, text, false)
  end

  defp deliver_user_message(s, text, new_invocation? \\ true) do
    s = begin_work(s)

    evidence =
      if new_invocation?,
        do: Recorder.begin(s.opts[:evidence_recorder], s.provider),
        else: s.evidence

    conn = if evidence && new_invocation?, do: Map.put(s.conn, :evidence, evidence), else: s.conn
    drive(%{s | evidence: evidence, conn: conn}, s.provider.user_input(text))
  end

  # ── acquire a turn (the ONLY mode-specific step) ──────────────────────────────
  defp drive(%{mode: :request_response} = s, input) do
    s = begin_work(s)
    generation = s.request.generation
    parent = self()
    %{provider: p, conn: c} = s

    {:ok, task} =
      Task.start_link(fn ->
        own_deadline_process(s.opts, :own_worker, self())
        # Preserve the caller's failure without emitting a second Task crash report
        # containing provider payloads before the Session can redact its diagnostics.
        try do
          result =
            try do
              p.poll_turn(c, input)
            rescue
              e -> {:error, {:provider_error, e}}
            end

          send(parent, {:turn, generation, result})
        catch
          :exit, :normal ->
            :ok

          :exit, reason ->
            send(parent, {:poll_task_failed, self(), reason})

          :throw, reason ->
            send(parent, {:poll_task_failed, self(), {{:nocatch, reason}, __STACKTRACE__}})
        end
      end)

    {:noreply, %{s | poll_task: task}}
  end

  defp drive(%{mode: :streaming} = s, input) do
    s = begin_work(s)
    s = ensure_stream_attempt(s)

    case s.provider.push_input(s.conn, input) do
      :ok ->
        {:noreply, %{s | turn_events: []}}

      # A sync run/2 surfaces a post failure; a live session stays alive (the message is dropped,
      # matching the old fire-and-forget POST) rather than silently dying with no notify.
      {:error, reason} ->
        if s.caller, do: stop_error(s, reason), else: live_push_error(s, reason)
    end
  end

  defp live_push_error(s, reason) do
    Recorder.observe(evidence_attempt(s), :transport_error, error_code: Recorder.code(reason))

    Recorder.observe(evidence_attempt(s), :attempt_end,
      result: :error,
      error_code: Recorder.code(reason)
    )

    s = finish_evidence(s, {:error, reason})
    s = complete_request(s, {:error, reason})
    live_reply(%{s | turn_events: []})
  end

  defp ensure_stream_attempt(%State{evidence: nil} = s), do: s

  defp ensure_stream_attempt(s) do
    case evidence_attempt(s) do
      %Recorder.Context{attempt_id: nil} = evidence ->
        %{s | conn: Map.put(s.conn, :evidence, Recorder.attempt(evidence))}

      _ ->
        s
    end
  end

  # History has already been recorded with historical provenance and deduplicated
  # by the provider. Process it before queued stream events can observe the grown seen set.
  defp recover_events(%State{request: %Request{generation: nil}} = s, _events),
    do: {:noreply, s}

  defp recover_events(s, events) do
    Enum.reduce_while(events, {:noreply, s}, fn ev, {:noreply, s} ->
      s = %{s | turn_events: s.turn_events ++ [ev]}
      s = checkpoint_partial(s)
      forward_with_delta(s, ev)

      result =
        if s.provider.turn_boundary?(ev),
          do: handle_turn(s, s.turn_events),
          else: {:noreply, s}

      case result do
        {:noreply, _} -> {:cont, result}
        {:noreply, _, {:continue, :next_message}} -> {:halt, result}
        {:stop, _, _} -> {:halt, result}
      end
    end)
  end

  # ── shared per-turn handling ──────────────────────────────────────────────────
  defp handle_turn(s, turn_events) do
    s = %{s | events: s.events ++ turn_events, turns: s.turns + 1, turn_events: []}
    tr = s.provider.normalize(turn_events)
    s = accumulate(s, tr)
    s = checkpoint(s, %{session_result(s, tr, tr.terminal) | in_flight: :none})
    s = checkpoint(s, %{s.request.snapshot | transcript: transcript_of(s)})
    emit_tool_use_telemetry(s, tr.custom_tool_uses)

    # The frozen governance hook: plain data in, plain verdict out. Hosts compose
    # policy here (budget caps, grant checks); this library ships only the mechanism.
    case run_turn_guard(s) do
      :cont ->
        continue_turn(s, tr)

      {:halt, reason} ->
        stop_error(s, {:halted, reason})
    end
  end

  defp run_turn_guard(%{turn_guard: nil}), do: :cont

  defp run_turn_guard(s) do
    s.turn_guard.(%{
      usage: s.usage,
      turns: s.turns,
      session_id: s.info.session_id
    })
  end

  defp continue_turn(s, tr) do
    cond do
      s.turns > s.max_turns ->
        stop_error(s, {:max_turns_exceeded, s.max_turns})

      tr.terminal == :requires_action ->
        handle_requires_action(s, tr)

      # Terminal-tool enforcement: an :end_turn that never called the required tool
      # re-drives with a re-prompt; re-prompt turns count against :max_turns.
      tr.terminal == :end_turn and missing_terminal_tool?(s) and s.reprompts_left > 0 ->
        input = s.provider.user_input(terminal_reprompt(s.enforced_terminal_tool))
        drive(%{s | reprompts_left: s.reprompts_left - 1}, input)

      tr.terminal == :end_turn and missing_terminal_tool?(s) ->
        finish(s, %{tr | stop_reason: :no_terminal_tool})

      true ->
        finish(s, tr)
    end
  end

  # A `requires_action` turn either carries custom tool uses to run and resume with,
  # or resolved to an empty batch — the classic idle-recovery shape handled by
  # `handle_empty_requires_action/2`.
  defp handle_requires_action(s, %{custom_tool_uses: []} = tr),
    do: handle_empty_requires_action(s, tr)

  defp handle_requires_action(s, tr) do
    results = run_tools(tr.custom_tool_uses, s)
    drive(s, s.provider.resume_input(tr.custom_tool_uses, results))
  end

  # A `requires_action` turn whose batch resolved to zero `custom_tool_uses` (the classic
  # shape: an idle references ids that live in an earlier, already-processed batch — see
  # `Provider.pending_tool_uses/1`). An empty resume must NEVER be sent (the API rejects it
  # outright), so recover via the provider's optional `pending_tool_uses/1` — keyed off the
  # session's own accumulated history, no extra round trip — the same recovery `reconnect/3`
  # already does across a stream drop. Nothing recoverable is a genuine protocol-state
  # error, surfaced loudly instead of the doomed empty resume.
  defp handle_empty_requires_action(s, tr) do
    case recoverable_tool_uses(s) do
      [] ->
        stop_error(s, {:unresolved_requires_action, tr.stop_reason})

      recovered ->
        emit_tool_use_telemetry(s, recovered)
        results = run_tools(recovered, s)
        s = %{s | custom_tool_uses: append_new_tool_uses(s.custom_tool_uses, recovered)}
        drive(s, s.provider.resume_input(recovered, results))
    end
  end

  # `recovered` uses may already have been accumulated when their originating turn
  # resolved (the issue-61 recovery shape) — append only the ones whose id isn't
  # already present, so the public `SessionResult.custom_tool_uses` never carries
  # a duplicate id for a recovered tool use.
  defp append_new_tool_uses(existing, recovered) do
    existing_ids = MapSet.new(existing, & &1.id)
    existing ++ Enum.reject(recovered, &MapSet.member?(existing_ids, &1.id))
  end

  defp recoverable_tool_uses(s) do
    if Code.ensure_loaded?(s.provider) and function_exported?(s.provider, :pending_tool_uses, 1) do
      s.provider.pending_tool_uses(s.events)
    else
      []
    end
  end

  defp missing_terminal_tool?(%{enforced_terminal_tool: nil}), do: false

  defp missing_terminal_tool?(%{enforced_terminal_tool: tool} = s),
    do: not Enum.any?(s.custom_tool_uses, &(&1.name == tool))

  # Wording relocated verbatim from an internal agent runner's Core.Runner.Directives
  # (eval-gate continuity for consumers migrating off that loop).
  defp terminal_reprompt(terminal_tool),
    do:
      "You returned a response without calling #{terminal_tool}. You MUST call " <>
        "#{terminal_tool} now to finish — produce the result via #{terminal_tool}."

  defp accumulate(s, %TurnResult{} = tr) do
    %{
      s
      | custom_tool_uses: s.custom_tool_uses ++ tr.custom_tool_uses,
        server_tool_uses: s.server_tool_uses ++ tr.server_tool_uses,
        usage: add_usage(s.usage, tr.usage)
    }
  end

  defp add_usage(acc, usage), do: Usage.add(acc, usage)

  # Per-turn observability + a duplicate-id regression sentinel: custom_tool_uses are unique by id by
  # construction, so a duplicate reaching here is a regression (a duplicate id in the resume makes
  # a provider reject the next turn).
  defp emit_tool_use_telemetry(s, custom_tool_uses) do
    ids = Enum.map(custom_tool_uses, & &1.id)

    :telemetry.execute(
      [:req_managed_agents, :session, :tool_uses],
      %{tool_use_count: length(ids)},
      Map.merge(s.meta, %{turn: s.turns, tool_use_ids: ids})
    )

    case ids -- Enum.uniq(ids) do
      [] ->
        :ok

      dups ->
        Logger.warning(
          "duplicate tool_use id(s) #{inspect(dups)} at turn #{s.turns} — providers reject resumes carrying duplicates"
        )
    end
  end

  defp run_tools(custom_tool_uses, s) do
    s = begin_work(s)

    custom_tool_uses
    |> Task.async_stream(
      fn %ToolUse{id: id, name: name, input: input} ->
        own_deadline_process(s.opts, :own_worker, self())
        Tools.execute(s.handler, id, name, input, s.context, s.info, s.meta, evidence_attempt(s))
      end,
      max_concurrency: @max_tool_concurrency,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.map(fn {:ok, r} -> r end)
  end

  # Re-run unanswered tool calls recovered on reconnect, then resume the loop.
  defp redrive(s, pending) do
    results = run_tools(pending, s)
    drive(s, s.provider.resume_input(pending, results))
  end

  # #79: reconnect/3 is optional. A provider that resumes (resumed?/1 true) but has no
  # event history to recover (request_response reattach) may omit it — resume proceeds
  # with the conn as-is, nothing pending, seen-set unchanged.
  defp prepare_reconnect_evidence(%State{evidence: nil} = s), do: s

  defp prepare_reconnect_evidence(
         %State{provider: ReqManagedAgents.Providers.ClaudeManagedAgents} = s
       ) do
    conn =
      s.conn
      |> Map.put(:evidence, Recorder.attempt(s.evidence))
      |> Map.put(:evidence_attempt_started, true)

    %{s | conn: conn}
  end

  defp prepare_reconnect_evidence(s), do: s

  defp safe_reconnect(s) do
    Code.ensure_loaded?(s.provider)

    cond do
      function_exported?(s.provider, :reconnect_with_events, 3) ->
        s.provider.reconnect_with_events(s.conn, self(), s.seen)

      function_exported?(s.provider, :reconnect, 3) ->
        case s.provider.reconnect(s.conn, self(), s.seen) do
          {:ok, conn, pending, seen} -> {:ok, conn, pending, seen, []}
          result -> result
        end

      true ->
        {:ok, s.conn, [], s.seen, []}
    end
  end

  # Transcript seam: embed the provider's client-held history at terminal when the
  # optional callback exists. nil for server-held providers.
  defp transcript_of(s) do
    if Code.ensure_loaded?(s.provider) and function_exported?(s.provider, :transcript, 1) do
      s.provider.transcript(s.conn)
    else
      nil
    end
  end

  defp backoff_ms(%{reconnect_attempts: n}),
    do: min(500 * Integer.pow(2, min(n, 7)), :timer.minutes(60))

  defp session_result(s, tr, terminal) do
    %SessionResult{
      terminal: terminal,
      stop_reason: tr.stop_reason,
      session_id: s.info.session_id,
      text: tr.text,
      custom_tool_uses: s.custom_tool_uses,
      server_tool_uses: s.server_tool_uses,
      usage: s.usage,
      turns: s.turns,
      events: s.events,
      transcript: s.request.snapshot.transcript
    }
  end

  defp finish(s, %TurnResult{} = tr) do
    if s.mode == :streaming, do: Recorder.observe(evidence_attempt(s), :attempt_end, result: :ok)

    :telemetry.execute(
      [:req_managed_agents, :session, :terminal],
      %{},
      Map.put(s.meta, :terminal, tr.terminal)
    )

    result = %{session_result(s, tr, tr.terminal) | in_flight: :none}
    # Real terminal reached — reset the reconnect backoff for any subsequent live activity.
    reply(%{s | reconnect_attempts: 0}, {:ok, result})
  end

  defp stop_error(s, reason) do
    if s.mode == :streaming do
      Recorder.observe(evidence_attempt(s), :transport_error, error_code: Recorder.code(reason))

      Recorder.observe(evidence_attempt(s), :attempt_end,
        result: :error,
        error_code: Recorder.code(reason)
      )
    end

    reply(s, {:error, reason})
  end

  defp stream_failed(s) do
    Recorder.observe(evidence_attempt(s), :transport_error, error_code: "transport_error")

    Recorder.observe(evidence_attempt(s), :attempt_end,
      result: :error,
      error_code: "transport_error"
    )

    Recorder.observe(evidence_attempt(s), :retry, error_code: "transport_error")
    retire_attempt(s)
  end

  defp native_evidence(%State{
         evidence: nil,
         provider: ReqManagedAgents.Providers.ClaudeManagedAgents,
         opts: opts
       }) do
    if is_pid(opts[:evidence_recorder]), do: opts[:evidence_recorder]
  end

  defp native_evidence(s), do: evidence_attempt(s)

  defp retire_attempt(%State{evidence: nil} = s), do: s

  defp retire_attempt(s) do
    conn =
      s.conn
      |> Map.put(:evidence, s.evidence)
      |> Map.delete(:evidence_attempt_started)

    %{s | conn: conn}
  end

  defp retire_invocation(%State{evidence: nil} = s), do: s

  defp retire_invocation(s) do
    s = retire_attempt(s)
    %{s | evidence: nil, conn: Map.put(s.conn, :evidence, nil)}
  end

  defp evidence_attempt(%State{evidence: nil}), do: nil

  defp evidence_attempt(%State{conn: conn, evidence: evidence}),
    do: Map.get(conn, :evidence, evidence)

  defp finish_evidence(s, result) do
    fields =
      case result do
        {:ok, _} -> [result: :ok]
        {:error, reason} -> [result: :error, error_code: Recorder.code(reason)]
      end

    Recorder.observe(s.evidence, :invocation_end, fields)
    retire_invocation(s)
  end

  # A synchronous run/2 caller gets the result and the GenServer stops; a live session
  # (no caller) stays alive after a non-error terminal to accept follow-up messages.
  defp reply(s, result) do
    s = finish_evidence(s, result)
    s = complete_request(s, result)
    if s.caller || match?({:error, _}, result), do: {:stop, :normal, s}, else: live_reply(s)
  end

  defp live_reply(%State{request: %Request{pending_messages: []}} = s), do: {:noreply, s}
  defp live_reply(s), do: {:noreply, s, {:continue, :next_message}}

  defp complete_request(s, result) do
    snapshot =
      case result do
        {:ok, snapshot} -> snapshot
        {:error, _reason} -> %{s.request.snapshot | terminal: :terminated}
      end

    completion_ack(Completion.finish(s.request.owner, s.request.generation, result, snapshot))
    %{s | request: %{s.request | generation: nil, snapshot: snapshot}}
  end

  defp begin_request(s),
    do: begin_request(s, %SessionResult{session_id: s.info.session_id, usage: Usage.zero()})

  defp begin_request(s, snapshot) do
    pending = if s.request, do: s.request.pending_messages, else: []

    request =
      Request.new(s.opts[:completion_owner], make_ref(), snapshot, pending_messages: pending)

    completion_ack(Completion.begin_request(request.owner, request.generation, snapshot))
    %{s | request: request}
  end

  defp checkpoint(s, snapshot) do
    completion_ack(Completion.checkpoint(s.request.owner, s.request.generation, snapshot))
    %{s | request: %{s.request | snapshot: snapshot}}
  end

  defp mark_in_flight(%State{request: %Request{generation: nil}} = s), do: s
  defp mark_in_flight(s), do: begin_work(s)
  defp begin_work(s), do: checkpoint(s, %{s.request.snapshot | in_flight: :unknown})

  defp checkpoint_partial(s),
    do:
      checkpoint(s, %{s.request.snapshot | events: s.events ++ s.turn_events, in_flight: :unknown})

  # A Converse-envelope event is a single-key map (%{"messageStop" => …}).
  defp envelope_type(%{} = ev), do: ev |> Map.keys() |> List.first()
  defp envelope_type(_), do: nil

  defp exports_text_delta?(provider),
    do: Code.ensure_loaded?(provider) and function_exported?(provider, :text_delta, 1)

  # Additive normalization: the synthetic delta follows the raw event through the same
  # handler path and is never accumulated into events (raw preservation).
  defp forward_with_delta(%{delta?: false} = s, ev), do: forward_raw(s, ev)

  defp forward_with_delta(s, ev) do
    forward_raw(s, ev)

    case s.provider.text_delta(ev) do
      chunk when is_binary(chunk) and chunk != "" ->
        forward_raw(s, %{"type" => "rma.text_delta", "text" => chunk})

      _ ->
        :ok
    end
  end

  defp forward_raw(%{handler: h, context: ctx, info: info}, ev) when is_atom(h) and h != nil do
    cond do
      Code.ensure_loaded?(h) and function_exported?(h, :handle_event, 3) ->
        h.handle_event(ev, ctx, info)

      function_exported?(h, :handle_event, 2) ->
        h.handle_event(ev, ctx)

      true ->
        :ok
    end

    :ok
  end

  defp forward_raw(_s, _ev), do: :ok

  # Session identity for handler callbacks: every provider answers session_id/1
  # (Claude mints it at open; Bedrock echoes the caller-supplied id).
  defp build_info(provider, conn, meta),
    do: %SessionInfo{session_id: provider.session_id(conn), provider: provider, metadata: meta}

  # Metadata passthrough: correlation ids minted by a routing layer (request ids,
  # decision ids, …) ride model_config into telemetry AND handle_event's
  # SessionInfo, uniformly across providers. model_config wins on key conflict —
  # the route response is the closer source.
  defp model_config_metadata(opts) do
    case opts[:model_config] do
      %{metadata: %{} = m} -> m
      _ -> %{}
    end
  end

  defoverridable handle_info: 2, handle_call: 3, handle_cast: 2

  @impl true
  def handle_info(message, state),
    do: diagnostic_boundary(fn -> super(message, state) end, state)

  @impl true
  def handle_call(message, from, state),
    do: diagnostic_boundary(fn -> super(message, from, state) end, state)

  @impl true
  def handle_cast(message, state),
    do: diagnostic_boundary(fn -> super(message, state) end, state)

  # OTP appends callback exception stacks after format_status; argument-bearing
  # frames must remain in the caller's reason rather than its diagnostic stack.
  defp diagnostic_boundary(callback, state) do
    callback.()
  catch
    :error, reason -> {:stop, {reason, __STACKTRACE__}, state}
    :exit, reason -> {:stop, reason, state}
    :throw, reason -> {:stop, {{:nocatch, reason}, __STACKTRACE__}, state}
  end
end
