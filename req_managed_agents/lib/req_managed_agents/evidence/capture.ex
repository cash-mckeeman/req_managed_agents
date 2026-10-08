defmodule ReqManagedAgents.Evidence.Capture do
  @moduledoc "Versioned private evidence, validated as one capture before serialization."
  alias ReqManagedAgents.Evidence

  alias ReqManagedAgents.Evidence.{
    Content,
    Correlation,
    Diagnostic,
    Error,
    Options,
    Record,
    Source,
    Validation
  }

  @enforce_keys [:capture_id, :provider, :started_at, :ended_at]
  defstruct [
    :capture_id,
    :provider,
    :session_id,
    :started_at,
    :ended_at,
    version: 1,
    sources: [],
    records: [],
    correlations: [],
    diagnostics: []
  ]

  @type t :: %__MODULE__{
          version: 1,
          capture_id: String.t(),
          provider: :managed | :agentcore,
          session_id: String.t() | nil,
          started_at: DateTime.t(),
          ended_at: DateTime.t(),
          sources: [Source.t()],
          records: [Record.t()],
          correlations: [Correlation.t()],
          diagnostics: [Diagnostic.t()]
        }
  @providers %{"managed" => :managed, "agentcore" => :agentcore}

  @doc "Validates identities and references, then applies retention and aggregate bounds."
  @spec new(map(), keyword() | Options.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs, opts \\ []) do
    with {:ok, options} <- Options.new(opts), {:ok, capture} <- parse(attrs) do
      capture
      |> annotate()
      |> deduplicate()
      |> retain(options.content)
      |> bound(options)
    end
  end

  @doc false
  @spec restore(map()) :: {:ok, t()} | {:error, Error.t()}
  def restore(attrs) do
    with {:ok, capture} <- parse(attrs) do
      {:ok, capture |> annotate() |> retain(:retain)}
    end
  end

  @doc false
  @spec parse(map()) :: {:ok, t()} | {:error, Error.t()}
  def parse(attrs) when is_map(attrs) do
    with 1 <- Validation.get(attrs, :version, 1),
         {:ok, fields} <-
           Validation.fields(attrs, [
             {:capture_id, &Validation.id/1, nil},
             {:provider, &Validation.enum(&1, @providers), nil},
             {:session_id, &Validation.optional(&1, fn v -> Validation.id(v) end), nil},
             {:started_at, &Validation.utc/1, nil},
             {:ended_at, &Validation.utc/1, nil},
             {:sources, &Validation.list(&1, fn v -> Source.new(v) end), []},
             {:records, &Validation.list(&1, fn v -> Record.parse(v) end), []},
             {:correlations, &Validation.list(&1, fn v -> Correlation.new(v) end), []},
             {:diagnostics, &Validation.list(&1, fn v -> Diagnostic.new(v) end), []}
           ]),
         capture = struct!(__MODULE__, fields),
         true <- valid_identity?(capture),
         true <- valid_references?(capture) do
      {:ok, capture}
    else
      {:error, _} = error -> error
      false -> Error.error(:invalid_reference)
      _ -> Error.error(:unsupported_version)
    end
  end

  def parse(_), do: Error.error(:invalid_input)

  defp valid_identity?(c) do
    Validation.ordered?(c.started_at, c.ended_at) and
      unique?(c.sources, & &1.id) and unique?(c.records, & &1.id) and
      unique?(c.records, &{&1.source_id, &1.ordinal}) and known_session?(c) and
      Enum.all?(
        c.records,
        &(Validation.ordered?(c.started_at, &1.observed_at) and
            Validation.ordered?(&1.observed_at, c.ended_at))
      ) and valid_sources?(c)
  end

  defp valid_sources?(capture) do
    kinds =
      if capture.provider == :managed,
        do: [:rma_local, :claude_session, :claude_thread],
        else: [:rma_local, :agentcore_stream, :cloudwatch]

    sources = Map.new(capture.sources, &{&1.id, &1.kind})

    Enum.all?(capture.sources, &(&1.kind in kinds)) and
      Enum.all?(capture.records, fn record ->
        local_source = Map.get(sources, record.source_id) == :rma_local
        local_source == (record.kind == :local)
      end)
  end

  defp known_session?(%{session_id: id}) when is_binary(id), do: true

  defp known_session?(c) do
    c.records != [] and Enum.all?(c.sources, &(&1.kind == :rma_local)) and
      Enum.all?(c.records, &(&1.kind == :local)) and
      Enum.any?(
        c.records,
        &(&1.payload.type in [:transport_failed, :attempt_finished, :invocation_finished] and
            (&1.payload.error_code != nil or &1.payload.result == :error))
      )
  end

  defp unique?(values, fun), do: length(values) == MapSet.size(MapSet.new(values, fun))

  defp valid_references?(c) do
    sources = MapSet.new(c.sources, & &1.id)
    records = MapSet.new(c.records, & &1.id)

    Enum.all?(c.records, &MapSet.member?(sources, &1.source_id)) and
      Enum.all?(c.correlations, &correlation_resolves?(&1, records)) and
      Enum.all?(c.diagnostics, fn d ->
        (d.source_id == nil or MapSet.member?(sources, d.source_id)) and
          (d.record_id == nil or MapSet.member?(records, d.record_id))
      end)
  end

  defp correlation_resolves?(link, ids) do
    MapSet.member?(ids, link.from_record_id) and
      Enum.all?(link.evidence_record_ids, &MapSet.member?(ids, &1)) and
      (link.target.namespace != :record or MapSet.member?(ids, link.target.id))
  end

  defp annotate(capture) do
    diagnostics =
      capture.records
      |> Enum.filter(& &1.validation_issue?)
      |> Enum.map(&diagnostic(:unsupported_record, &1))

    %{capture | diagnostics: capture.diagnostics ++ diagnostics}
  end

  defp deduplicate(capture) do
    {records, _, aliases, diagnostics} =
      Enum.reduce(capture.records, {[], %{}, %{}, []}, fn record, state ->
        deduplicate_record(record, state)
      end)

    remap = &Map.get(aliases, &1, &1)

    correlations =
      Enum.map(capture.correlations, fn link ->
        target =
          if link.target.namespace == :record,
            do: %{link.target | id: remap.(link.target.id)},
            else: link.target

        %{
          link
          | from_record_id: remap.(link.from_record_id),
            target: target,
            evidence_record_ids: Enum.map(link.evidence_record_ids, remap)
        }
      end)

    diagnostics =
      Enum.map(
        capture.diagnostics ++ Enum.reverse(diagnostics),
        &%{&1 | record_id: remap.(&1.record_id)}
      )

    %{
      capture
      | records: Enum.reverse(records),
        correlations: correlations,
        diagnostics: diagnostics
    }
  end

  defp deduplicate_record(%{native_id: nil} = record, {records, seen, aliases, diagnostics}),
    do: {[record | records], seen, aliases, diagnostics}

  defp deduplicate_record(%{content_state: state} = record, {records, seen, aliases, diagnostics})
       when state != :retained,
       do: {[record | records], seen, aliases, diagnostics}

  defp deduplicate_record(record, {records, seen, aliases, diagnostics}) do
    key = {record.source_id, record.native_id}
    previous = Map.get(seen, key, [])

    case Enum.find(
           previous,
           &(&1.payload == record.payload and &1.occurred_at == record.occurred_at)
         ) do
      nil ->
        diagnostics =
          if previous == [],
            do: diagnostics,
            else: [diagnostic(:conflicting_duplicate, record) | diagnostics]

        {[record | records], Map.put(seen, key, [record | previous]), aliases, diagnostics}

      duplicate ->
        {records, seen, Map.put(aliases, record.id, duplicate.id), diagnostics}
    end
  end

  defp retain(capture, content) do
    records = Enum.map(capture.records, &Content.apply(&1, content))

    diagnostics =
      Enum.flat_map(records, fn record ->
        if record.kind == :native and record.content_state != :retained,
          do: [diagnostic(:content_unavailable, record)],
          else: []
      end)

    %{capture | records: records, diagnostics: Enum.uniq(capture.diagnostics ++ diagnostics)}
  end

  defp bound(capture, options) do
    {kept, dropped} = Enum.split(capture.records, options.max_records)
    capture = if dropped == [], do: capture, else: truncate(capture, kept, length(dropped))
    pages = Enum.sum(Enum.map(capture.sources, & &1.pages))
    capture = if pages > options.max_pages, do: page_gap(capture), else: capture

    with {:ok, bounded} <- bound_bytes(capture, options.max_bytes) do
      if known_session?(bounded), do: {:ok, bounded}, else: Error.error(:bound_exceeded)
    end
  end

  defp page_gap(capture) do
    {:ok, d} = Diagnostic.new(%{code: :bound_exceeded, count: 0})
    {:ok, gap} = Diagnostic.new(%{code: :capture_gap, count: 0})

    %{
      capture
      | sources: Enum.map(capture.sources, &partial/1),
        diagnostics: capture.diagnostics ++ [d, gap]
    }
  end

  defp bound_bytes(capture, limit) do
    if encoded_size(capture) <= limit do
      {:ok, capture}
    else
      empty = truncate(capture, [], length(capture.records))

      if encoded_size(empty) <= limit do
        {:ok, fit_prefix(capture, limit, 1, length(capture.records) - 1, empty)}
      else
        Error.error(:bound_exceeded)
      end
    end
  end

  defp fit_prefix(_capture, _limit, low, high, best) when low > high, do: best

  defp fit_prefix(capture, limit, low, high, best) do
    count = div(low + high, 2)

    candidate =
      truncate(capture, Enum.take(capture.records, count), length(capture.records) - count)

    if encoded_size(candidate) <= limit do
      fit_prefix(capture, limit, count + 1, high, candidate)
    else
      fit_prefix(capture, limit, low, count - 1, best)
    end
  end

  defp encoded_size(capture), do: byte_size(Jason.encode!(Evidence.to_wire(capture)))

  defp truncate(capture, kept, count) do
    ids = MapSet.new(kept, & &1.id)
    {links, lost} = Enum.split_with(capture.correlations, &correlation_resolves?(&1, ids))

    diagnostics =
      Enum.filter(
        capture.diagnostics,
        &(&1.record_id == nil or MapSet.member?(ids, &1.record_id))
      )

    {bounds, other} =
      Enum.split_with(diagnostics, &(&1.code == :bound_exceeded and &1.source_id == nil))

    {:ok, gap} =
      Diagnostic.new(%{
        code: :bound_exceeded,
        count: count + Enum.sum(Enum.map(bounds, & &1.count))
      })

    diagnostics =
      if lost == [],
        do: other ++ [gap],
        else: other ++ [gap, diagnostic(:invalid_correlation, nil, length(lost))]

    %{
      capture
      | records: kept,
        correlations: links,
        sources: Enum.map(capture.sources, &partial/1),
        diagnostics: diagnostics
    }
  end

  defp partial(%{status: :complete} = source),
    do: %{source | status: :partial, reason: :bound_exceeded}

  defp partial(source), do: source

  defp diagnostic(code, record, count \\ 1) do
    attrs = if record, do: %{source_id: record.source_id, record_id: record.id}, else: %{}
    {:ok, diagnostic} = Diagnostic.new(Map.merge(attrs, %{code: code, count: count}))
    diagnostic
  end
end
