defmodule ReqManagedAgents.Host.Locator do
  @moduledoc """
  Durable `external_id -> upstream identity` map over a `Store`. Reads and writes
  `Locator.Record` rows; translates the store's `:miss` (and any non-`Record`
  value found in a shared store) to the caller-facing `:error`.
  """

  alias ReqManagedAgents.Host.Locator.Record
  alias ReqManagedAgents.Host.Store

  @type external_id :: String.t()

  @spec put(Store.store(), Record.t()) :: :ok
  def put(store, %Record{} = record) do
    store_put(store, record.external_id, record)
  end

  @spec fetch(Store.store(), external_id()) :: {:ok, Record.t()} | :error
  def fetch(store, external_id) do
    case store_get(store, external_id) do
      {:ok, %Record{} = record} -> {:ok, record}
      _ -> :error
    end
  end

  @spec mark_context_sent(Store.store(), external_id()) :: :ok | :error
  def mark_context_sent(store, external_id) do
    update(store, external_id, fn %Record{} = record -> %Record{record | context_sent: true} end)
  end

  # Transitioning to :deleted also drops the sibling transcript (record-removal cleanup);
  # :active/:terminated leave it alone — reattach after :terminated still wants its history.
  @spec set_status(Store.store(), external_id(), Record.status()) :: :ok | :error
  def set_status(store, external_id, :deleted) do
    with :ok <-
           update(store, external_id, fn %Record{} = record ->
             %Record{record | status: :deleted}
           end) do
      delete_transcript(store, external_id)
    end
  end

  def set_status(store, external_id, status) do
    update(store, external_id, fn %Record{} = record -> %Record{record | status: status} end)
  end

  @spec list(Store.store()) :: [Record.t()]
  def list(store) do
    {mod, opts} = store
    ref = mod.ref(opts)

    ref
    |> mod.all()
    |> Enum.map(fn {_key, value} -> value end)
    |> Enum.filter(&match?(%Record{}, &1))
  end

  @spec list_by(Store.store(), map()) :: [Record.t()]
  def list_by(store, metadata) do
    store
    |> list()
    |> Enum.filter(fn %Record{metadata: record_metadata} ->
      Enum.all?(metadata, fn {key, value} -> Map.get(record_metadata, key) == value end)
    end)
  end

  @doc "Persist a session transcript under the sibling key `{:transcript, external_id}`."
  @spec put_transcript(Store.store(), external_id(), [map()]) :: :ok
  def put_transcript(store, external_id, messages) when is_list(messages) do
    store_put(store, {:transcript, external_id}, messages)
  end

  @doc "Fetch a persisted transcript. `:miss` when none was stored."
  @spec fetch_transcript(Store.store(), external_id()) :: {:ok, [map()]} | :miss
  def fetch_transcript(store, external_id) do
    store_get(store, {:transcript, external_id})
  end

  @doc "Delete a persisted transcript (record-removal cleanup)."
  @spec delete_transcript(Store.store(), external_id()) :: :ok
  def delete_transcript(store, external_id) do
    store_delete(store, {:transcript, external_id})
  end

  @spec update(Store.store(), external_id(), (Record.t() -> Record.t())) :: :ok | :error
  defp update(store, external_id, transform) do
    case fetch(store, external_id) do
      {:ok, record} ->
        store_put(store, external_id, transform.(record))
        :ok

      :error ->
        :error
    end
  end

  @spec store_put(Store.store(), Store.key(), Store.value()) :: :ok
  defp store_put({mod, opts}, key, value) do
    ref = mod.ref(opts)
    mod.put(ref, key, value)
  end

  @spec store_get(Store.store(), Store.key()) :: {:ok, term()} | :miss
  defp store_get({mod, opts}, key) do
    ref = mod.ref(opts)
    mod.get(ref, key)
  end

  @spec store_delete(Store.store(), Store.key()) :: :ok
  defp store_delete({mod, opts}, key) do
    ref = mod.ref(opts)
    mod.delete(ref, key)
  end
end
