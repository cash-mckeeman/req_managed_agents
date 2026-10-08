defmodule ReqManagedAgents.Evidence.CloudWatch.Query do
  @moduledoc "An explicit CloudWatch log destination, UTC interval and native session/trace selection."
  alias ReqManagedAgents.Evidence.{CloudWatchClient, Error, Source, Validation}
  @enforce_keys [:region, :log_group, :from, :to, :session_id]
  defstruct [:region, :log_group, :from, :to, :session_id, trace_ids: []]

  @type t :: %__MODULE__{
          region: String.t(),
          log_group: String.t(),
          from: DateTime.t(),
          to: DateTime.t(),
          session_id: String.t(),
          trace_ids: [String.t()]
        }

  @doc "Rejects unknown fields, invalid destinations, non-UTC/reversed intervals and non-hex trace IDs."
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = attrs), do: attrs |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs) do
    with true <- Validation.only_keys?(attrs, ~w(region log_group from to session_id trace_ids)a),
         region = Validation.get(attrs, :region),
         true <- CloudWatchClient.valid_region?(region),
         group = Validation.get(attrs, :log_group),
         true <-
           is_binary(group) and byte_size(group) in 1..512 and
             Regex.match?(~r/\A[.\-_\/#A-Za-z0-9]+\z/, group),
         {:ok, interval} <- Source.Interval.new(attrs),
         true <- DateTime.to_unix(interval.from, :millisecond) >= 0,
         {:ok, session} <- Validation.safe_id(Validation.get(attrs, :session_id)),
         traces = Validation.get(attrs, :trace_ids, []),
         true <- is_list(traces) and Enum.all?(traces, &trace_id?/1) do
      {:ok,
       %__MODULE__{
         region: region,
         log_group: group,
         from: interval.from,
         to: interval.to,
         session_id: session,
         trace_ids: Enum.uniq(traces)
       }}
    else
      _ -> Error.error(:invalid_input)
    end
  end

  def new(_), do: Error.error(:invalid_input)

  @doc false
  @spec trace_id?(term()) :: boolean()
  def trace_id?(value),
    do:
      is_binary(value) and Regex.match?(~r/\A[0-9a-fA-F]{32}\z/, value) and
        value != String.duplicate("0", 32)
end

defmodule ReqManagedAgents.Evidence.CloudWatch do
  @moduledoc """
  Bounded post-run enrichment from one caller-selected CloudWatch Logs group.

  Supply the destination configured for your telemetry, a UTC interval, explicit
  credentials, and `logs:FilterLogEvents` permission for that group. Only
  [FilterLogEvents](https://docs.aws.amazon.com/AmazonCloudWatchLogs/latest/APIReference/API_FilterLogEvents.html)
  is called, with `unmask: false`; no logging configuration or IAM changes occur.
  CloudWatch requires the optional `:ex_aws_auth` dependency, without EventStream.

  Retained payloads preserve each outer log record and its exact message string.
  The recognized message dialect is standard OTLP JSON `resourceSpans` /
  `scopeSpans` / `spans`, with hex trace/span IDs, unsigned nanosecond timestamps,
  and a string `session.id` attribute on the span or resource. This is a supported
  standard input shape, **not verified live AgentCore harness output**. Matching
  spans establish only same-session association. Unsupported messages and native
  identity mismatches remain private raw evidence and make coverage partial.

  A drained cursor covers retrieval for the declared interval at collection time;
  delayed telemetry and provider-internal activity may still be absent. Budgets
  include prior evidence, inspected records, pages and retained bytes; they do not
  bound the HTTP adapter's response buffer. The deadline cancels an active request.
  If coverage metadata cannot fit alongside bounded prior evidence, returns
  a `:bound_exceeded` error instead of evicting that evidence.
  """
  alias ReqManagedAgents.Evidence
  alias ReqManagedAgents.Evidence.CloudWatch.Query

  alias ReqManagedAgents.Evidence.{
    Capture,
    CloudWatchClient,
    Content,
    Correlation,
    Diagnostic,
    Error,
    NativeIdentity,
    Options,
    Record,
    Source,
    Validation
  }

  defmodule State do
    @moduledoc false
    @enforce_keys [
      :capture,
      :query,
      :options,
      :client,
      :source,
      :deadline,
      :pages,
      :count,
      :bytes,
      :prior_count
    ]
    defstruct [
      :capture,
      :query,
      :options,
      :client,
      :source,
      :deadline,
      :pages,
      :count,
      :bytes,
      :prior_count,
      identities: [],
      halted?: false
    ]

    @type t :: %__MODULE__{
            capture: Capture.t(),
            query: Query.t(),
            options: Options.t(),
            client: CloudWatchClient.t(),
            source: Source.t(),
            deadline: integer(),
            pages: non_neg_integer(),
            count: non_neg_integer(),
            bytes: non_neg_integer(),
            prior_count: non_neg_integer(),
            identities: [NativeIdentity.t() | nil],
            halted?: boolean()
          }
  end

  @doc "Enriches matching AgentCore evidence; opts accept an explicit client or credentials/resolver and transport."
  @spec enrich(Capture.t(), Query.t(), Options.t(), keyword()) ::
          {:ok, Capture.t()} | {:error, Error.t()}
  def enrich(capture, query, options, opts \\ [])

  def enrich(
        %Capture{provider: :agentcore} = capture,
        %Query{} = query,
        %Options{} = options,
        opts
      ) do
    with {:ok, query} <- Query.new(query),
         {:ok, options} <- Options.new(options),
         true <- capture.session_id == query.session_id,
         {:ok, client} <- client(query, opts),
         {:ok, capture} <- Capture.new(capture, options) do
      capture |> initialize(query, options, client) |> collect() |> finish()
    else
      false -> Error.error(:invalid_reference)
      {:error, _} = error -> error
    end
  end

  def enrich(_, _, _, _), do: Error.error(:invalid_input)

  defp client(query, opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- length(opts) == length(Enum.uniq(Keyword.keys(opts))),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:client, :credentials, :transport])),
         {:ok, client} <- build_client(query, opts),
         true <- client.region == query.region do
      {:ok, client}
    else
      _ -> Error.error(:invalid_options)
    end
  end

  defp client(_, _), do: Error.error(:invalid_options)

  defp build_client(_query, client: %CloudWatchClient{} = client),
    do: CloudWatchClient.new(client)

  defp build_client(query, opts) do
    if Keyword.has_key?(opts, :client),
      do: Error.error(:invalid_options),
      else: CloudWatchClient.new(Keyword.put(opts, :region, query.region))
  end

  defp initialize(capture, query, options, client) do
    %State{
      capture: capture,
      prior_count: length(capture.records),
      query: query,
      options: options,
      client: client,
      source: %Source{
        id: id(),
        kind: :cloudwatch,
        scope: query.region <> ":" <> query.log_group,
        interval: %Source.Interval{from: query.from, to: query.to},
        status: :complete
      },
      deadline: System.monotonic_time(:millisecond) + options.timeout_ms,
      pages: Enum.sum(Enum.map(capture.sources, & &1.pages)),
      count: max(length(capture.records), Enum.sum(Enum.map(capture.sources, & &1.records_seen))),
      bytes: byte_size(Jason.encode!(Evidence.to_wire(capture)))
    }
  end

  defp collect(state) do
    reservation = encoded_size(state.source) + 1024

    if exhausted?(state) or state.bytes + reservation >= state.options.max_bytes do
      diagnostics = Enum.map([:bound_exceeded, :capture_gap], &diagnostic(&1, nil, nil, 0))

      %{
        state
        | source: nil,
          capture: %{
            state.capture
            | diagnostics: Enum.uniq(state.capture.diagnostics ++ diagnostics)
          }
      }
    else
      pages(%{state | bytes: state.bytes + reservation}, nil, MapSet.new())
    end
  end

  defp pages(state, cursor, seen) do
    if exhausted?(state),
      do: gap(%{state | halted?: true}, :bound_exceeded, 0),
      else: request_page(state, cursor, seen)
  end

  defp request_page(state, cursor, seen) do
    state = %{
      state
      | pages: state.pages + 1,
        source: %{state.source | pages: state.source.pages + 1}
    }

    case request(state, cursor) do
      {:ok, %{"events" => events} = body} when is_list(events) ->
        state = records(state, events)
        continue(state, Map.get(body, "nextToken"), seen)

      {:ok, _} ->
        gap(state, :incomplete_retrieval)

      {:error, :deadline} ->
        gap(%{state | halted?: true}, :bound_exceeded, 0)

      {:error, _} ->
        unavailable(state)
    end
  end

  defp unavailable(state) do
    state = gap(state, :source_unavailable)

    if state.source.pages == 1,
      do: %{state | source: %{state.source | status: :unavailable}},
      else: state
  end

  defp continue(%State{halted?: true} = state, _, _), do: state
  defp continue(state, nil, _), do: state

  defp continue(state, cursor, seen) when is_binary(cursor) do
    cond do
      String.trim(cursor) == "" -> gap(state, :incomplete_retrieval)
      MapSet.member?(seen, cursor) -> gap(state, :cursor_cycle)
      true -> pages(state, cursor, MapSet.put(seen, cursor))
    end
  end

  defp continue(state, _, _), do: gap(state, :incomplete_retrieval)

  defp records(state, events) do
    first = state.source.records_seen + 1

    state = %{
      state
      | source: %{state.source | records_seen: state.source.records_seen + length(events)}
    }

    events
    |> Enum.with_index(first)
    |> Enum.reduce_while(state, &inspect_record/2)
  end

  defp inspect_record({payload, ordinal}, state) do
    if state.count >= state.options.max_records or remaining(state) <= 0 do
      {:halt,
       gap(%{state | halted?: true}, :bound_exceeded, state.source.records_seen - ordinal + 1)}
    else
      state = admit(state, payload, ordinal)
      if state.halted?, do: {:halt, state}, else: {:cont, state}
    end
  end

  defp admit(state, payload, ordinal) when is_map(payload) do
    {:ok, record} =
      Record.parse(%{
        id: id(),
        source_id: state.source.id,
        ordinal: ordinal,
        native_id: native_id(payload),
        observed_at: max_time(state.capture.ended_at, DateTime.utc_now()),
        occurred_at: event_time(payload),
        clock: :wall,
        kind: :native,
        payload: payload
      })

    matched? = matching_message?(payload, state.query)
    record = %{record | validation_issue?: not matched?}
    links = if matched?, do: [session_link(record, state.query)], else: []
    identity = NativeIdentity.new(record, state.options.content)
    record = Content.apply(record, state.options.content)
    cost = encoded_size(record) + encoded_size(links) + :erlang.external_size(identity) + 800

    if state.bytes + cost > state.options.max_bytes do
      gap(%{state | halted?: true}, :bound_exceeded, state.source.records_seen - ordinal + 1)
    else
      state = %{
        state
        | count: state.count + 1,
          bytes: state.bytes + cost,
          identities: [identity | state.identities],
          capture: %{
            state.capture
            | records: state.capture.records ++ [record],
              correlations: state.capture.correlations ++ links
          }
      }

      if matched?, do: state, else: gap(state, :unsupported_record)
    end
  end

  defp admit(state, _, _), do: gap(%{state | count: state.count + 1}, :unsupported_record)

  defp native_id(payload) do
    case Validation.id(Map.get(payload, "eventId")) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  defp event_time(%{"timestamp" => millis}) when is_integer(millis) and millis >= 0 do
    case DateTime.from_unix(millis, :millisecond) do
      {:ok, time} -> time
      _ -> nil
    end
  end

  defp event_time(_), do: nil

  defp session_link(record, query) do
    {:ok, link} =
      Correlation.new(%{
        from_record_id: record.id,
        relation: :same_session,
        target: %{namespace: :session, id: query.session_id},
        evidence_record_ids: [record.id]
      })

    link
  end

  # Only this standard envelope is recognized; log messages are otherwise opaque.
  defp matching_message?(
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

  defp matching_message?(_, _), do: false

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
      %{"key" => "session.id", "value" => %{"stringValue" => id}}, {:ok, ids}
      when is_binary(id) ->
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

  defp gap(state, code, count \\ 1) do
    {matching, others} =
      Enum.split_with(
        state.capture.diagnostics,
        &(&1.source_id == state.source.id and &1.record_id == nil and &1.code == code)
      )

    diagnostic =
      diagnostic(code, state.source.id, nil, count + Enum.sum(Enum.map(matching, & &1.count)))

    diagnostics = others ++ [diagnostic]

    diagnostics =
      if code == :bound_exceeded,
        do: Enum.uniq(diagnostics ++ [diagnostic(:capture_gap, state.source.id, nil, 0)]),
        else: diagnostics

    %{
      state
      | capture: %{state.capture | diagnostics: diagnostics},
        source: %{state.source | status: :partial, reason: code}
    }
  end

  defp diagnostic(code, source, record, count) do
    {:ok, value} =
      Diagnostic.new(%{code: code, source_id: source, record_id: record, count: count})

    value
  end

  defp exhausted?(state),
    do:
      state.halted? or state.pages >= state.options.max_pages or
        state.count >= state.options.max_records or state.bytes >= state.options.max_bytes or
        remaining(state) <= 0

  defp remaining(state), do: state.deadline - System.monotonic_time(:millisecond)
  defp encoded_size(value), do: value |> Validation.wire() |> Jason.encode!() |> byte_size()
  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  defp max_time(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  defp request(state, cursor) do
    request = %{
      "logGroupName" => state.query.log_group,
      "startTime" => DateTime.to_unix(state.query.from, :millisecond),
      "endTime" => DateTime.to_unix(state.query.to, :millisecond),
      "unmask" => false,
      "limit" => min(10_000, max(1, state.options.max_records - state.count))
    }

    request = if cursor, do: Map.put(request, "nextToken", cursor), else: request
    client = %{state.client | timeout_ms: max(1, remaining(state))}
    owner = self()
    token = make_ref()
    callers = [owner | Process.get(:"$callers", [])]

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        send(owner, {token, CloudWatchClient.filter_log_events(client, request)})
      end)

    await(pid, monitor, token, max(0, remaining(state)))
  end

  defp await(pid, monitor, token, timeout) do
    receive do
      {^token, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        {:error, :unavailable}
    after
      timeout ->
        Process.exit(pid, :kill)
        receive do: ({:DOWN, ^monitor, :process, ^pid, _} -> :ok)
        receive do: ({^token, _} -> :ok), after: (0 -> :ok)
        {:error, :deadline}
    end
  end

  defp finish(state) do
    sources =
      if state.source, do: state.capture.sources ++ [state.source], else: state.capture.sources

    result =
      Capture.new(
        %{
          state.capture
          | sources: sources,
            ended_at: max_time(state.capture.ended_at, DateTime.utc_now()),
            diagnostics:
              state.capture.diagnostics ++
                NativeIdentity.diagnostics(Enum.reverse(state.identities))
        },
        state.options
      )

    with {:ok, capture} <- result do
      kept = MapSet.new(capture.records, & &1.id)
      prior = Enum.take(state.capture.records, state.prior_count)

      if Enum.all?(prior, &MapSet.member?(kept, &1.id)),
        do: {:ok, capture},
        else: Error.error(:bound_exceeded)
    end
  end
end
