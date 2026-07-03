defmodule ReqManagedAgents.Provisioner do
  @moduledoc """
  Hash-keyed provision cache. `ensure/3` returns a cached provider `handle` for a given
  `{provider, spec}`, calling `provider.provision/2` only on a miss. The handle is the
  durable artifact; where the `{hash → handle}` mapping lives is pluggable via the
  `ReqManagedAgents.Provisioner.Store` behaviour (`:store` option) — in-process ETS by
  default, or a persistent store (e.g. `Store.File`) for reuse across OS processes.
  """
  require Logger
  alias ReqManagedAgents.Provider
  alias ReqManagedAgents.Provisioner.Store

  @default_store {Store.ETS, :req_managed_agents_provisions}

  @spec ensure(module(), Provider.spec(), keyword()) ::
          {:ok, Provider.handle()} | {:error, term()}
  def ensure(provider, spec, opts \\ []) do
    {mod, sopts} = opts[:store] || @default_store
    key = "provision:" <> hash({provider, spec})

    case safe_get(mod, sopts, key) do
      {:ok, handle} ->
        {:ok, handle}

      :miss ->
        case provider.provision(spec, opts) do
          {:ok, handle} ->
            safe_put(mod, sopts, key, handle)
            {:ok, handle}

          {:error, reason} ->
            {:error, {:provision_failed, reason}}
        end
    end
  end

  @doc """
  Drop any cache entry whose value is `handle` (called after teardown). With a
  persistent store (e.g. `Store.File`) the handle must be JSON-encodable —
  same constraint as `ensure/3`'s store writes; non-encodable values raise.
  """
  @spec evict(Provider.handle(), keyword()) :: :ok
  def evict(handle, opts \\ []) do
    {mod, sopts} = opts[:store] || @default_store
    mod.delete_value(sopts, handle)
    :ok
  end

  @doc false
  def reset do
    {_mod, table} = @default_store
    if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    :ok
  end

  defdelegate ensure_environment(client, env_spec, opts \\ []),
    to: ReqManagedAgents.Provisioner.Environments

  defdelegate tag(base, tag, digest_or_handle, opts \\ []),
    to: ReqManagedAgents.Provisioner.Environments

  defdelegate resolve(ref, opts \\ []),
    to: ReqManagedAgents.Provisioner.Environments

  @doc false
  def hash(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic])) |> Base.encode16()

  # A broken cache must not block provisioning (loud-but-safe).
  defp safe_get(mod, sopts, key) do
    mod.get(sopts, key)
  rescue
    e ->
      Logger.warning("provision store get failed (treating as miss): #{inspect(e)}")
      :miss
  end

  defp safe_put(mod, sopts, key, value) do
    mod.put(sopts, key, value)
  rescue
    e -> Logger.warning("provision store put failed (handle still returned): #{inspect(e)}")
  end
end
