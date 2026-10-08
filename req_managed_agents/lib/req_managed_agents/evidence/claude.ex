defmodule ReqManagedAgents.Evidence.Claude do
  @moduledoc """
  Bounded, GET-only retrieval of persisted Claude session and thread evidence.

  Uses the documented [session events](https://platform.claude.com/docs/en/api/beta/sessions/events/list),
  [threads](https://platform.claude.com/docs/en/api/beta/sessions/threads/list), and
  [thread events](https://platform.claude.com/docs/en/api/beta/sessions/threads/events/list) endpoints.
  Each source reports its own coverage. Thread enumeration descriptors are native
  records; they consume the same aggregate limits as event records. A completed
  enumeration does not establish complete provider-internal visibility.

  Missing page data, malformed cursors, cycles and request failures return partial
  evidence. The deadline cancels an in-flight request. Bounds cover inspected
  records and encoded capture bytes, not the HTTP adapter's response buffer.
  Unvisited child histories leave enumeration coverage partial. Historical events
  have no inferred local invocation or retry-attempt identity.
  """
  alias ReqManagedAgents.Client
  alias ReqManagedAgents.Evidence

  alias ReqManagedAgents.Evidence.{
    Capture,
    Content,
    Diagnostic,
    Error,
    Fetch,
    NativeIdentity,
    Record,
    Source,
    Validation
  }

  defmodule State do
    @moduledoc false
    @enforce_keys [:config, :capture, :deadline, :pages, :count, :bytes]
    defstruct [
      :config,
      :capture,
      :deadline,
      :pages,
      :count,
      :bytes,
      :enumeration_id,
      identities: [],
      halted?: false
    ]

    @type t :: %__MODULE__{
            config: Fetch.t(),
            capture: Capture.t(),
            deadline: integer(),
            pages: non_neg_integer(),
            count: non_neg_integer(),
            bytes: non_neg_integer(),
            enumeration_id: String.t() | nil,
            identities: [NativeIdentity.t() | nil],
            halted?: boolean()
          }
  end

  @doc "Collects one session, preserving a matching prior capture's identities and references."
  @spec fetch(String.t(), Fetch.t()) :: {:ok, Capture.t()} | {:error, Error.t()}
  def fetch(session_id, %Fetch{} = input) do
    with {:ok, session_id} <- Validation.id(session_id),
         {:ok, config} <- Fetch.new(input),
         true <- config.prior == nil or config.prior.session_id == session_id,
         {:ok, config} <- prepare_prior(config) do
      config
      |> initialize(session_id)
      |> collect(:session, nil)
      |> collect_threads()
      |> finish()
    else
      false -> Error.error(:invalid_reference)
      {:error, _} = error -> error
    end
  end

  def fetch(_, _), do: Error.error(:invalid_input)

  defp prepare_prior(%Fetch{prior: nil} = config), do: {:ok, config}

  defp prepare_prior(%Fetch{} = config) do
    with {:ok, capture} <- Capture.new(config.prior, config.options) do
      {:ok, %{config | prior: capture}}
    end
  end

  defp initialize(%Fetch{} = config, session_id) do
    now = DateTime.utc_now()

    capture =
      config.prior ||
        %Capture{
          capture_id: id(),
          provider: :managed,
          session_id: session_id,
          started_at: now,
          ended_at: now
        }

    %State{
      config: config,
      capture: capture,
      deadline: System.monotonic_time(:millisecond) + config.options.timeout_ms,
      pages: Enum.sum(Enum.map(capture.sources, & &1.pages)),
      count: length(capture.records),
      bytes: byte_size(Jason.encode!(Evidence.to_wire(capture)))
    }
  end

  defp collect_threads(%State{} = state) do
    {state, threads} = retrieve(state, :threads, nil)

    threads
    |> Enum.uniq()
    |> collect_children(state)
  end

  defp collect_children([], state), do: state

  defp collect_children([thread | rest], state) do
    source = new_source(state, :thread, thread)

    if exhausted?(state) or
         state.bytes + source_reservation(source) >= state.config.options.max_bytes do
      mark_pending(state)
    else
      collect_children(rest, collect(state, :thread, thread))
    end
  end

  defp mark_pending(state) do
    enumeration = Enum.find(state.capture.sources, &(&1.id == state.enumeration_id))
    {state, enumeration} = gap(%{state | halted?: true}, enumeration, :bound_exceeded, 0)

    sources =
      Enum.map(state.capture.sources, fn source ->
        if source.id == enumeration.id, do: enumeration, else: source
      end)

    %{state | capture: %{state.capture | sources: sources}}
  end

  defp collect(%State{} = state, kind, thread_id) do
    {state, _} = retrieve(state, kind, thread_id)
    state
  end

  defp retrieve(%State{} = state, kind, thread_id) do
    source = new_source(state, kind, thread_id)

    if exhausted?(state) or
         state.bytes + source_reservation(source) >= state.config.options.max_bytes do
      {skip_source(state), []}
    else
      state = %{state | bytes: state.bytes + source_reservation(source)}
      state = if kind == :threads, do: %{state | enumeration_id: source.id}, else: state
      {state, source, threads} = pages(state, source, {kind, thread_id}, nil, %{}, [])
      {%{state | capture: %{state.capture | sources: state.capture.sources ++ [source]}}, threads}
    end
  end

  defp skip_source(state) do
    gaps =
      Enum.map([:bound_exceeded, :capture_gap], fn code ->
        {:ok, diagnostic} = Diagnostic.new(%{code: code, count: 0})
        diagnostic
      end)

    capture = %{state.capture | diagnostics: Enum.uniq(state.capture.diagnostics ++ gaps)}
    %{state | capture: capture, halted?: true}
  end

  defp new_source(state, kind, thread_id) do
    %Source{
      id: id(),
      kind: if(kind == :session, do: :claude_session, else: :claude_thread),
      scope: scope(state.capture.session_id, kind, thread_id),
      status: :complete
    }
  end

  # Reserve terminal coverage diagnostics and counter growth before starting a source.
  defp source_reservation(source), do: encoded_size(source) + 512

  defp scope(session, :session, _), do: session
  defp scope(_session, :thread, thread), do: thread

  defp scope(session, :threads, _) do
    locator = "sessions/#{session}/threads"

    if byte_size(locator) <= 1024,
      do: locator,
      else: "threads:" <> Base.encode16(:crypto.hash(:sha256, session))
  end

  defp pages(state, source, endpoint, cursor, seen, threads) do
    if exhausted?(state) do
      {state, source} = gap(%{state | halted?: true}, source, :bound_exceeded, 0)
      {state, source, threads}
    else
      request_page(state, source, endpoint, cursor, seen, threads)
    end
  end

  defp request_page(state, source, endpoint, cursor, seen, threads) do
    state = %{state | pages: state.pages + 1}
    source = %{source | pages: source.pages + 1}

    case request(state, endpoint, cursor) do
      {:ok, %{"data" => data} = body} when is_list(data) ->
        source = %{source | records_seen: source.records_seen + length(data)}
        {state, source, threads} = records(state, source, endpoint, data, threads)
        continue(state, source, endpoint, Map.get(body, "next_page"), seen, threads)

      {:ok, _} ->
        {state, source} = gap(state, source, :incomplete_retrieval)
        {state, source, threads}

      {:error, :deadline} ->
        {state, source} = gap(%{state | halted?: true}, source, :bound_exceeded, 0)
        {state, source, threads}

      {:error, _} ->
        {state, source} = gap(state, source, :source_unavailable)
        source = if source.pages == 1, do: %{source | status: :unavailable}, else: source
        {state, source, threads}
    end
  end

  defp continue(state, source, _endpoint, _cursor, _seen, threads) when state.halted?,
    do: {state, source, threads}

  defp continue(state, source, _endpoint, nil, _seen, threads), do: {state, source, threads}

  defp continue(state, source, endpoint, cursor, seen, threads) when is_binary(cursor) do
    cond do
      String.trim(cursor) == "" ->
        {state, source} = gap(state, source, :incomplete_retrieval)
        {state, source, threads}

      Map.has_key?(seen, cursor) ->
        {state, source} = gap(state, source, :cursor_cycle)
        {state, source, threads}

      true ->
        pages(state, source, endpoint, cursor, Map.put(seen, cursor, true), threads)
    end
  end

  defp continue(state, source, _endpoint, _cursor, _seen, threads) do
    {state, source} = gap(state, source, :incomplete_retrieval)
    {state, source, threads}
  end

  defp records(state, source, endpoint, data, threads) do
    first = source.records_seen - length(data) + 1

    data
    |> Enum.with_index(first)
    |> Enum.reduce_while({state, source, threads}, fn {payload, ordinal},
                                                      {state, source, threads} ->
      case inspect_record(state, source, payload, ordinal) do
        {:ok, state} ->
          {state, source, threads} = thread(state, source, endpoint, payload, threads)
          {:cont, {state, source, threads}}

        {:invalid, state} ->
          {state, source} = gap(state, source, :unsupported_record)
          {:cont, {state, source, threads}}

        {:bound, state} ->
          {state, source} =
            gap(
              %{state | halted?: true},
              source,
              :bound_exceeded,
              source.records_seen - ordinal + 1
            )

          {:halt, {state, source, threads}}
      end
    end)
  end

  defp inspect_record(state, source, payload, ordinal) do
    if state.count >= state.config.options.max_records or remaining(state) <= 0 do
      {:bound, state}
    else
      admit(state, source, payload, ordinal)
    end
  end

  defp admit(state, source, payload, ordinal) when is_map(payload) do
    attrs = %{
      id: id(),
      source_id: source.id,
      native_id: native_id(payload),
      ordinal: ordinal,
      observed_at: DateTime.utc_now(),
      occurred_at: Map.get(payload, "processed_at"),
      clock: :wall,
      kind: :native,
      payload: payload
    }

    case Record.parse(attrs) do
      {:ok, record} ->
        malformed_id? = Map.get(payload, "id") != nil and record.native_id == nil

        admit_record(state, %{
          record
          | validation_issue?: record.validation_issue? or malformed_id?
        })

      {:error, _} ->
        {:invalid, %{state | count: state.count + 1}}
    end
  end

  defp admit(state, _, _, _), do: {:invalid, %{state | count: state.count + 1}}

  defp admit_record(state, record) do
    identity = NativeIdentity.new(record, state.config.options.content)
    record = Content.apply(record, state.config.options.content)

    bytes =
      record
      |> Map.from_struct()
      |> Map.delete(:validation_issue?)
      |> Validation.wire()
      |> Jason.encode!()
      |> byte_size()

    bytes =
      bytes + record_diagnostics_size(record, identity) + :erlang.external_size(identity) + 1

    if state.count >= state.config.options.max_records or
         state.bytes + bytes > state.config.options.max_bytes do
      {:bound, state}
    else
      capture = %{state.capture | records: state.capture.records ++ [record]}

      {:ok,
       %{
         state
         | capture: capture,
           count: state.count + 1,
           bytes: state.bytes + bytes,
           identities: [identity | state.identities]
       }}
    end
  end

  defp record_diagnostics_size(record, identity) do
    codes = if record.validation_issue?, do: [:unsupported_record], else: []
    codes = if record.content_state == :retained, do: codes, else: [:content_unavailable | codes]
    codes = if identity == nil, do: codes, else: [:conflicting_duplicate | codes]

    Enum.sum(
      Enum.map(codes, fn code ->
        {:ok, diagnostic} =
          Diagnostic.new(%{code: code, source_id: record.source_id, record_id: record.id})

        encoded_size(diagnostic) + 1
      end)
    )
  end

  defp encoded_size(value), do: value |> Validation.wire() |> Jason.encode!() |> byte_size()

  defp native_id(payload) do
    case Validation.id(Map.get(payload, "id")) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  defp thread(state, source, {:threads, _}, payload, threads) do
    case native_id(payload) do
      nil ->
        {state, source} = gap(state, source, :unsupported_record)
        {state, source, threads}

      id ->
        {state, source, threads ++ [id]}
    end
  end

  defp thread(state, source, _, _, threads), do: {state, source, threads}

  defp exhausted?(state) do
    state.halted? or state.pages >= state.config.options.max_pages or
      state.count >= state.config.options.max_records or
      state.bytes >= state.config.options.max_bytes or remaining(state) <= 0
  end

  defp gap(state, source, code, count \\ 1) do
    {:ok, diagnostic} = Diagnostic.new(%{code: code, source_id: source.id, count: count})

    {matching, other} =
      Enum.split_with(
        state.capture.diagnostics,
        &(&1.code == code and &1.source_id == source.id and &1.record_id == nil)
      )

    diagnostic = %{diagnostic | count: count + Enum.sum(Enum.map(matching, & &1.count))}
    diagnostics = other ++ [diagnostic]

    diagnostics =
      if code == :bound_exceeded do
        {:ok, unknown} = Diagnostic.new(%{code: :capture_gap, source_id: source.id, count: 0})
        Enum.uniq(diagnostics ++ [unknown])
      else
        diagnostics
      end

    capture = %{state.capture | diagnostics: diagnostics}
    {%{state | capture: capture}, %{source | status: :partial, reason: code}}
  end

  defp request(state, endpoint, cursor) do
    params = %{limit: min(100, max(1, state.config.options.max_records - state.count))}
    params = if cursor == nil, do: params, else: Map.put(params, :page, cursor)
    client = state.config.client

    client = %{
      client
      | req_options:
          Keyword.merge(client.req_options,
            retry: false,
            receive_timeout: max(1, remaining(state))
          )
    }

    owner = self()
    token = make_ref()
    callers = [owner | Process.get(:"$callers", [])]

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        send(owner, {token, safe_request(client, state.capture.session_id, endpoint, params)})
      end)

    await(pid, monitor, token, max(0, remaining(state)))
  end

  defp safe_request(client, session, endpoint, params) do
    case endpoint do
      {:session, _} -> Client.list_events(client, session, params)
      {:threads, _} -> Client.list_threads(client, session, params)
      {:thread, thread} -> Client.list_thread_events(client, session, thread, params)
    end
  rescue
    _ -> {:error, :request_failed}
  catch
    _, _ -> {:error, :request_failed}
  end

  defp await(pid, monitor, token, timeout) do
    receive do
      {^token, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        {:error, :request_failed}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        end

        receive do
          {^token, _} -> :ok
        after
          0 -> :ok
        end

        {:error, :deadline}
    end
  end

  defp remaining(state), do: state.deadline - System.monotonic_time(:millisecond)
  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp finish(%State{} = state) do
    diagnostics = NativeIdentity.diagnostics(Enum.reverse(state.identities))

    Capture.new(
      %{
        state.capture
        | ended_at: DateTime.utc_now(),
          diagnostics: state.capture.diagnostics ++ diagnostics
      },
      state.config.options
    )
  end
end
