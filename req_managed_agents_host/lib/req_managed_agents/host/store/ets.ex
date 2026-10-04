defmodule ReqManagedAgents.Host.Store.ETS do
  @moduledoc """
  Default `Store` implementation: a named public ETS `:set` table, owned by a
  tiny GenServer so the table outlives any individual caller. Process-local —
  empty in every fresh OS process, gone when the owner stops.
  """
  use GenServer

  @behaviour ReqManagedAgents.Host.Store

  @impl true
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, name)
  end

  @impl true
  def ref(opts), do: Keyword.fetch!(opts, :name)

  @impl true
  def put(table, key, value) do
    :ets.insert(table, {key, value})
    :ok
  end

  @impl true
  def get(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  end

  @impl true
  def delete(table, key) do
    :ets.delete(table, key)
    :ok
  end

  @impl true
  def all(table), do: :ets.tab2list(table)

  @impl true
  def init(name) do
    :ets.new(name, [:named_table, :public, :set])
    {:ok, name}
  end
end
