defmodule ReqManagedAgents.Evidence.Recorder.Context do
  @moduledoc false
  @enforce_keys [:recorder, :invocation_id]
  defstruct [:recorder, :invocation_id, :attempt_id]
  @type t :: %__MODULE__{recorder: pid(), invocation_id: String.t(), attempt_id: String.t() | nil}
end

defmodule ReqManagedAgents.Evidence.Recorder do
  @moduledoc """
  Caller-owned, bounded observations for one provider session, independent of Session lifetime. Stop the recorder
  after taking its snapshot. Recording failures never retry provider work.

  Admission charges external-term bytes plus record overhead across queued and retained
  observations; snapshots additionally enforce the encoded artifact limit. Local monotonic
  ticks are nanoseconds in the recorder-scoped clock. Rejected
  observations and unfinished invocations produce a partial capture. A barrier timeout
  returns available validated records with a gap, rather than a consistent completion claim.

  AgentCore observations begin at decoded Converse frames. Original EventStream headers,
  byte encoding and malformed frames discarded by the transport decoder are unavailable.
  """
  use GenServer
  alias ReqManagedAgents.Evidence.{Capture, Diagnostic, Error, LocalRecord, Options, Record}
  alias ReqManagedAgents.Evidence.Record.Payload
  alias ReqManagedAgents.Evidence.Recorder.Context

  @enforce_keys [:table, :counters, :options, :capture_id, :clock_id, :started_at]
  defstruct [:table, :counters, :options, :capture_id, :clock_id, :started_at, ordinal: 0]

  @type t :: %__MODULE__{
          table: :ets.tid(),
          counters: :atomics.atomics_ref(),
          options: Options.t(),
          capture_id: String.t(),
          clock_id: String.t(),
          started_at: DateTime.t(),
          ordinal: non_neg_integer()
        }

  @doc "Starts a recorder linked to its caller, using validated capture options."
  @spec start_link(Options.t()) :: GenServer.on_start()
  def start_link(%Options{} = options), do: GenServer.start_link(__MODULE__, options)

  @doc "Sets provider identity before observations; a missing session may be filled after open."
  @spec context(pid() | nil, :managed | :agentcore, String.t() | nil) :: :ok
  def context(pid, provider, session_id) do
    with %__MODULE__{} = state <- handle(pid), true <- provider in [:managed, :agentcore] do
      :ets.insert_new(state.table, {:context, provider, nil})

      update_context(state, provider, session_id, :ets.lookup(state.table, :context))
    end

    :ok
  catch
    _, _ -> :ok
  end

  defp update_context(_state, provider, session_id, [{:context, provider, old}])
       when session_id == nil or session_id == old, do: :ok

  defp update_context(state, provider, session_id, [{:context, provider, nil}]) do
    changed =
      :ets.select_replace(
        state.table,
        [{{:context, provider, nil}, [], [{{:context, provider, session_id}}]}]
      )

    if changed == 0,
      do: update_context(state, provider, session_id, :ets.lookup(state.table, :context))
  end

  defp update_context(state, _provider, _session_id, _context) do
    :ets.insert(state.table, {:invalid_context, true})
    lost(state)
  end

  @doc "Admits an observation without waiting; rejected observations increment the gap count."
  @spec emit(pid() | nil, LocalRecord.t() | Record.t()) :: :ok
  def emit(pid, record) do
    with %__MODULE__{} = state <- handle(pid) do
      bytes = :erlang.external_size(record) + 2048

      if reserve(state, bytes) do
        send(
          pid,
          {:observation, record, bytes, DateTime.utc_now(), System.monotonic_time(:nanosecond)}
        )
      else
        lost(state)
      end
    end

    :ok
  catch
    _, _ -> :ok
  end

  @doc "Returns bounded evidence, or a safe unavailable error when the recorder cannot be read."
  @spec snapshot(pid()) :: {:ok, Capture.t()} | {:error, Error.t()}
  def snapshot(pid) do
    case handle(pid) do
      %__MODULE__{} = state -> capture(state, barrier(pid, state.options.timeout_ms))
      _ -> Error.error(:recorder_unavailable)
    end
  catch
    _, _ -> Error.error(:recorder_unavailable)
  end

  @doc false
  @spec begin(pid() | nil, module()) :: Context.t() | nil
  def begin(pid, provider) when is_pid(pid) do
    case provider do
      ReqManagedAgents.Providers.BedrockAgentCore -> begin_context(pid, :agentcore)
      ReqManagedAgents.Providers.ClaudeManagedAgents -> begin_context(pid, :managed)
      _ -> nil
    end
  end

  def begin(_, _), do: nil

  defp begin_context(pid, provider) do
    context(pid, provider, nil)
    ctx = %Context{recorder: pid, invocation_id: id()}
    observe(ctx, :invocation_start)
    ctx
  end

  @doc false
  @spec attempt(Context.t() | nil) :: Context.t() | nil
  def attempt(nil), do: nil

  def attempt(%Context{} = ctx) do
    ctx = %{ctx | attempt_id: id()}
    observe(ctx, :attempt_start)
    ctx
  end

  @doc false
  @spec observe(Context.t() | nil, atom(), keyword()) :: :ok
  def observe(ctx, type, fields \\ [])
  def observe(nil, _, _), do: :ok

  def observe(%Context{} = ctx, type, fields) do
    attrs =
      Map.merge(
        %{type: type, invocation_id: ctx.invocation_id, attempt_id: ctx.attempt_id},
        Map.new(fields)
      )

    case LocalRecord.new(attrs) do
      {:ok, record} -> emit(ctx.recorder, record)
      _ -> :ok
    end
  catch
    _, _ -> :ok
  end

  @doc false
  @spec native(Context.t() | nil, map()) :: :ok
  def native(nil, _), do: :ok

  def native(%Context{} = ctx, payload) do
    # Validate and filter only after admission, so a large native frame never enters the mailbox.
    record = %Record{
      id: id(),
      source_id: "native",
      native_id: native_id(payload),
      ordinal: 1,
      observed_at: DateTime.utc_now(),
      clock: :none,
      kind: :native,
      payload: payload,
      content_state: :retained,
      invocation_id: ctx.invocation_id,
      attempt_id: ctx.attempt_id
    }

    emit(ctx.recorder, record)
  end

  @doc false
  @spec history(Context.t() | nil, map()) :: :ok
  def history(nil, _), do: :ok

  def history(%Context{} = ctx, payload) do
    emit(ctx.recorder, %Record{
      id: id(),
      source_id: "history",
      native_id: native_id(payload),
      ordinal: 1,
      observed_at: DateTime.utc_now(),
      clock: :none,
      kind: :native,
      payload: payload,
      content_state: :retained
    })
  end

  defp native_id(%{"id" => id}) when is_binary(id), do: id
  defp native_id(_), do: nil

  @doc false
  @spec code(term()) :: String.t()
  def code(:early_termination), do: "early_termination"
  def code(:timeout), do: "timeout"
  def code({:harness_stream_error, _, _}), do: "harness_stream_error"
  def code(_), do: "transport_error"

  @impl true
  def init(options) do
    case Options.new(options) do
      {:ok, options} ->
        state = %__MODULE__{
          table: :ets.new(__MODULE__, [:ordered_set, :public]),
          counters: :atomics.new(4, signed: true),
          options: options,
          capture_id: id(),
          clock_id: id(),
          started_at: DateTime.utc_now()
        }

        Process.put(__MODULE__, state)
        {:ok, state}

      {:error, error} ->
        {:stop, error}
    end
  end

  @impl true
  def handle_call(:barrier, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:observation, input, reserved, observed, ticks}, state) do
    ordinal = state.ordinal + 1

    case record(input, state, ordinal, observed, ticks) do
      {:ok, record} -> store_record(state, record, reserved)
      _ -> release(state, reserved)
    end

    :atomics.sub(state.counters, 3, 1)
    {:noreply, %{state | ordinal: ordinal}}
  end

  defp handle(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, __MODULE__)
      _ -> nil
    end
  end

  defp handle(_), do: nil

  # Reservations include retained bytes, so draining a slow mailbox cannot reopen a full store.
  defp reserve(state, bytes) do
    total = :atomics.add_get(state.counters, 1, bytes)
    count = :atomics.add_get(state.counters, 2, 1)

    if total <= state.options.max_bytes and count <= state.options.max_records do
      :atomics.add(state.counters, 3, 1)
      true
    else
      :atomics.sub(state.counters, 1, bytes)
      :atomics.sub(state.counters, 2, 1)
      false
    end
  end

  defp lost(state), do: :atomics.add(state.counters, 4, 1)

  defp release(state, bytes) do
    :atomics.sub(state.counters, 1, bytes)
    :atomics.sub(state.counters, 2, 1)
    lost(state)
  end

  defp store_record(state, record, reserved) do
    bytes = :erlang.external_size(record)

    if bytes <= reserved do
      :ets.insert(state.table, {{:record, record.ordinal}, record})
      :atomics.sub(state.counters, 1, reserved - bytes)
    else
      release(state, reserved)
    end
  end

  defp record(%LocalRecord{payload: %Payload{} = payload}, state, ordinal, observed, ticks) do
    payload = %{payload | clock_id: state.clock_id}

    payload =
      case payload.type do
        type when type in [:invocation_started, :attempt_started, :tool_started] ->
          %{payload | started_ticks: ticks}

        _ ->
          %{payload | ended_ticks: ticks}
      end

    Record.new(
      %{
        id: "record-#{ordinal}",
        source_id: "local",
        ordinal: ordinal,
        observed_at: observed,
        clock: :monotonic,
        clock_id: state.clock_id,
        monotonic_ticks: ticks,
        kind: :local,
        payload: payload,
        invocation_id: payload.invocation_id,
        attempt_id: payload.attempt_id
      },
      state.options
    )
  end

  defp record(%Record{kind: :native} = record, state, ordinal, observed, _ticks) do
    Record.new(
      %{
        record
        | id: "record-#{ordinal}",
          source_id: if(record.source_id == "history", do: "history", else: "native"),
          ordinal: ordinal,
          observed_at: observed
      },
      state.options
    )
  end

  defp record(_, _, _, _, _), do: Error.error(:invalid_input)

  defp barrier(pid, timeout) do
    GenServer.call(pid, :barrier, timeout)
  catch
    _, _ -> :timeout
  end

  defp capture(state, barrier) do
    false = :ets.member(state.table, :invalid_context)
    [{:context, provider, session_id}] = :ets.lookup(state.table, :context)
    records = :ets.select(state.table, [{{{:record, :_}, :"$1"}, [], [:"$1"]}])
    losses = :atomics.get(state.counters, 4)

    gap? =
      barrier != :ok or losses > 0 or :atomics.get(state.counters, 3) > 0 or unfinished?(records)

    diagnostics = if gap?, do: [diagnostic(:capture_gap, losses)], else: []
    status = if gap?, do: :partial, else: :complete

    local = %{
      id: "local",
      kind: :rma_local,
      scope: "local_lifecycle",
      status: status,
      records_seen: Enum.count(records, &(&1.kind == :local))
    }

    native = %{
      id: "native",
      kind: if(provider == :agentcore, do: :agentcore_stream, else: :claude_session),
      scope:
        if(provider == :agentcore, do: "decoded_converse_frames", else: "decoded_session_events"),
      status: status,
      records_seen: Enum.count(records, &(&1.kind == :native))
    }

    Capture.new(
      %{
        capture_id: state.capture_id,
        provider: provider,
        session_id: session_id,
        started_at: state.started_at,
        ended_at: DateTime.utc_now(),
        sources: capture_sources(local, native, records, session_id),
        records: records,
        diagnostics: diagnostics
      },
      state.options
    )
  end

  defp capture_sources(local, _native, _records, nil), do: [local]

  defp capture_sources(local, native, records, _session_id) do
    {history, live} = Enum.split_with(records, &(&1.source_id == "history"))
    native = %{native | records_seen: Enum.count(live, &(&1.kind == :native))}

    if history == [] do
      [local, native]
    else
      [
        local,
        native,
        %{
          native
          | id: "history",
            scope: "persisted_session_history",
            records_seen: length(history)
        }
      ]
    end
  end

  defp unfinished?(records) do
    Enum.reduce(records, MapSet.new(), fn
      %Record{kind: :local, payload: %Payload{type: type} = p}, active ->
        case type do
          :invocation_started -> MapSet.put(active, {:invocation, p.invocation_id})
          :invocation_finished -> MapSet.delete(active, {:invocation, p.invocation_id})
          :attempt_started -> MapSet.put(active, {:attempt, p.attempt_id})
          :attempt_finished -> MapSet.delete(active, {:attempt, p.attempt_id})
          _ -> active
        end

      _, active ->
        active
    end) != MapSet.new()
  end

  defp diagnostic(code, count) do
    {:ok, diagnostic} = Diagnostic.new(%{code: code, count: count})
    diagnostic
  end

  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end
