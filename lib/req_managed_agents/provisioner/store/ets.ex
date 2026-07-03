defmodule ReqManagedAgents.Provisioner.Store.ETS do
  @moduledoc """
  Default in-process store — a named public ETS table. Process-independent
  within one BEAM; empty in every fresh OS process (the original cache
  semantics, unchanged).
  """
  @behaviour ReqManagedAgents.Provisioner.Store

  @impl true
  def get(table, key) do
    case :ets.lookup(ensure_table(table), key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  end

  @impl true
  def put(table, key, value) do
    :ets.insert(ensure_table(table), {key, value})
    :ok
  end

  @impl true
  def delete(table, key) do
    :ets.delete(ensure_table(table), key)
    :ok
  end

  @impl true
  def delete_value(table, value) do
    :ets.match_delete(ensure_table(table), {:"$1", value})
    :ok
  end

  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined -> :ets.new(table, [:named_table, :public, :set])
      _ref -> table
    end
  end
end
