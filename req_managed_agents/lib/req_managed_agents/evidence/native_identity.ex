defmodule ReqManagedAgents.Evidence.NativeIdentity do
  @moduledoc false
  alias ReqManagedAgents.Evidence.{Diagnostic, Record}

  @enforce_keys [:source_id, :native_id, :record_id, :digest]
  defstruct [:source_id, :native_id, :record_id, :digest]

  @type t :: %__MODULE__{
          source_id: String.t(),
          native_id: String.t(),
          record_id: String.t(),
          digest: binary()
        }

  @spec new(Record.t(), :drop | :retain) :: t() | nil
  def new(%Record{kind: :native, content_state: :retained, native_id: id} = record, :drop)
      when is_binary(id) do
    digest =
      {canonical_payload(record.payload), record.occurred_at}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))

    %__MODULE__{
      source_id: record.source_id,
      native_id: id,
      record_id: record.id,
      digest: digest
    }
  end

  def new(%Record{}, _), do: nil

  defp canonical_payload(value) when is_float(value) do
    integer = trunc(value)
    if value == integer, do: integer, else: value
  end

  defp canonical_payload(value) when is_list(value), do: Enum.map(value, &canonical_payload/1)

  defp canonical_payload(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, canonical_payload(nested)} end)

  defp canonical_payload(value), do: value

  # Facts belong only to fresh admitted observations, never restored lossy payloads.
  @spec diagnostics([t() | nil]) :: [Diagnostic.t()]
  def diagnostics(facts) do
    {_, diagnostics} =
      Enum.reduce(facts, {%{}, []}, fn
        nil, state ->
          state

        %__MODULE__{} = fact, {seen, diagnostics} ->
          key = {fact.source_id, fact.native_id}
          previous = Map.get(seen, key, MapSet.new())

          diagnostics =
            if MapSet.size(previous) > 0 and not MapSet.member?(previous, fact.digest) do
              {:ok, diagnostic} =
                Diagnostic.new(%{
                  code: :conflicting_duplicate,
                  source_id: fact.source_id,
                  record_id: fact.record_id
                })

              [diagnostic | diagnostics]
            else
              diagnostics
            end

          {Map.put(seen, key, MapSet.put(previous, fact.digest)), diagnostics}
      end)

    Enum.reverse(diagnostics)
  end
end
