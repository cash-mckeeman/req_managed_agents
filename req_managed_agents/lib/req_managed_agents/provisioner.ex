defmodule ReqManagedAgents.Provisioner do
  @moduledoc """
  Hash-keyed provision cache. `ensure/3` returns a cached provider `handle` for a given
  `{provider, spec}`, plus the `:environment` digest and `:cache_scope` when given, calling
  `provider.provision/2` only on a miss. The handle is the durable artifact; where the
  `{hash → handle}` mapping lives is pluggable via the `ReqManagedAgents.Provisioner.Store`
  behaviour (`:store` option) — in-process ETS by default, or a persistent store (e.g.
  `Store.File`) for reuse across OS processes.
  """
  require Logger
  alias ReqManagedAgents.Environment
  alias ReqManagedAgents.Provider
  alias ReqManagedAgents.Provisioner.Store

  @default_store {Store.ETS, :req_managed_agents_provisions}

  @doc """
  Returns the cached handle for `spec`, provisioning it on a miss. The cache key
  covers `{provider, spec}`, the `:environment` digest when given, and
  `:cache_scope` when given.

  `:cache_scope` is an optional non-empty string naming the authority a handle
  belongs to, such as the account and endpoint whose credentials provision it,
  so the same spec provisioned under two accounts is never shared between them.
  Pass a reference rather than a credential, and change it when the authority
  changes. Any other value returns `{:error, {:invalid_opts, :cache_scope}}`
  without reading the store or calling the provider.
  """
  @spec ensure(module(), Provider.spec(), keyword()) ::
          {:ok, Provider.handle()} | {:error, term()}
  def ensure(provider, spec, opts \\ []) do
    {mod, sopts} = opts[:store] || @default_store

    # Fold the environment identity into the cache key — but ONLY when an
    # environment is present, so env-less keys stay byte-identical to pre-#70
    # (no forced re-provision on upgrade). An invalid environment surfaces as an
    # error rather than caching under a corrupt key.
    with {:ok, scope} <- cache_scope(opts),
         {:ok, env} <- Environment.Spec.new(opts[:environment]) do
      key = "provision:" <> hash(scoped_key(key_term(provider, spec, env), scope))

      case safe_get(mod, sopts, key) do
        {:ok, handle} -> {:ok, handle}
        :miss -> provision_and_cache(provider, spec, opts, mod, sopts, key)
      end
    end
  end

  defp cache_scope(opts) do
    case Keyword.fetch(opts, :cache_scope) do
      :error -> {:ok, nil}
      {:ok, scope} when is_binary(scope) and scope != "" -> {:ok, scope}
      {:ok, _} -> {:error, {:invalid_opts, :cache_scope}}
    end
  end

  defp scoped_key(key, nil), do: key
  defp scoped_key(key, scope), do: {:scope, scope, key}

  defp provision_and_cache(provider, spec, opts, mod, sopts, key) do
    case provider.provision(spec, opts) do
      {:ok, handle} ->
        safe_put(mod, sopts, key, handle)
        {:ok, handle}

      {:error, reason} ->
        {:error, {:provision_failed, reason}}
    end
  end

  defp key_term(provider, spec, nil), do: {provider, spec}
  defp key_term(provider, spec, env), do: {provider, spec, Environment.Spec.digest(env)}

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

  defdelegate prune_environments(client, base, opts \\ []),
    to: ReqManagedAgents.Provisioner.Environments

  defdelegate ensure_agent(client, agent_spec, opts \\ []),
    to: ReqManagedAgents.Provisioner.Agents

  defdelegate tag_agent(base, tag, digest_or_handle, opts \\ []),
    to: ReqManagedAgents.Provisioner.Agents

  defdelegate resolve_agent(ref, opts \\ []), to: ReqManagedAgents.Provisioner.Agents
  defdelegate prune_agents(client, base, opts \\ []), to: ReqManagedAgents.Provisioner.Agents

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
