defmodule ReqManagedAgents.Provisioner do
  @moduledoc """
  Hash-keyed provision cache. `ensure/3` returns a cached provider `handle` for a given
  `{provider, spec}`, calling `provider.provision/2` only on a miss. ETS-backed
  (process-independent); the handle is the durable artifact (persistable + reusable across
  processes), so the cache is an in-process optimization, not the source of truth.
  """
  alias ReqManagedAgents.Provider
  @table :req_managed_agents_provisions

  @spec ensure(module(), Provider.spec(), keyword()) ::
          {:ok, Provider.handle()} | {:error, term()}
  def ensure(provider, spec, opts \\ []) do
    table = ensure_table()
    key = hash({provider, spec})

    case :ets.lookup(table, key) do
      [{^key, handle}] ->
        {:ok, handle}

      [] ->
        case provider.provision(spec, opts) do
          {:ok, handle} ->
            :ets.insert(table, {key, handle})
            {:ok, handle}

          {:error, reason} ->
            {:error, {:provision_failed, reason}}
        end
    end
  end

  @doc "Drop any cache entry whose value is `handle` (called after teardown)."
  @spec evict(Provider.handle()) :: :ok
  def evict(handle) do
    if :ets.whereis(@table) != :undefined, do: :ets.match_delete(@table, {:"$1", handle})
    :ok
  end

  @doc false
  def reset,
    do: if(:ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table), else: :ok)

  defp hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic])) |> Base.encode16()

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _ref -> @table
    end
  end
end
