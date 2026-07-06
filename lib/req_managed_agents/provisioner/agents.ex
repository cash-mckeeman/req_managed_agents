defmodule ReqManagedAgents.Provisioner.Agents do
  @moduledoc """
  Agents as content-addressed managed entities: keyed by spec digest, created
  once, reused forever, superseded by NEW specs, destroyed only by explicit
  prune — the exact lifecycle `Provisioner.Environments` gives environments.

  The provider-side name is `<base>_<digest8>`, so a name collision can only
  mean "this exact agent already exists", and recovery by name is version-correct
  even with an empty store.
  """
  alias ReqManagedAgents.Agent.Spec
  alias ReqManagedAgents.Provisioner
  alias ReqManagedAgents.Provisioner.Store

  @default_store {Store.ETS, :req_managed_agents_provisions}

  @doc """
  Build-if-absent for an agent. Returns `{:ok, %{agent_id:, name:, digest:}}`.

  Opts: `:name` (base, default the spec's `name`), `:store` (`{module, store_opts}`),
  `:create_fun` / `:list_fun` (test seams; default to `ReqManagedAgents.Client`
  calls on the given client).
  """
  @spec ensure_agent(term(), Spec.t() | map(), keyword()) ::
          {:ok, %{agent_id: String.t(), name: String.t(), digest: String.t()}} | {:error, term()}
  def ensure_agent(client, spec_or_map, opts \\ []) do
    with {:ok, spec} <- Spec.new(spec_or_map) do
      do_ensure_agent(client, spec, opts)
    end
  end

  defp do_ensure_agent(client, %Spec{} = spec, opts) do
    base = opts[:name] || spec.name
    digest = Spec.digest(spec)
    name = base <> "_" <> digest
    {smod, sopts} = opts[:store] || @default_store
    key = "provision:agent:" <> Provisioner.hash({base, digest})
    digest_key = "digest:agent:" <> base <> ":" <> digest

    create_fun =
      opts[:create_fun] || fn body -> ReqManagedAgents.Client.create_agent(client, body) end

    list_fun =
      opts[:list_fun] || fn -> ReqManagedAgents.Client.list_agents(client, %{}) end

    with {:ok, stored} <- store_get(smod, sopts, key),
         {:ok, handle} <- normalize_or_miss(stored) do
      {:ok, handle}
    else
      :miss ->
        case build(create_fun, list_fun, spec, name, digest) do
          {:ok, handle} ->
            store_put(smod, sopts, key, handle)
            store_put(smod, sopts, digest_key, handle)
            {:ok, handle}

          error ->
            error
        end
    end
  end

  defp build(create_fun, list_fun, %Spec{} = spec, name, digest) do
    body = %{name: name, model: spec.model_config, system: spec.system_prompt, tools: spec.tools}

    case create_fun.(body) do
      {:ok, %{"id" => id}} -> {:ok, %{agent_id: id, name: name, digest: digest}}
      {:error, {:http_error, 409, _}} -> recover(list_fun, name, digest)
      {:error, reason} -> {:error, reason}
    end
  end

  # A 409 on create means a name collision. Since the provider-side name is
  # `<base>_<digest8>`, a live agent with this exact name IS this exact spec —
  # recovery by name is version-correct even with an empty store.
  defp recover(list_fun, name, digest) do
    with {:ok, %{"data" => agents}} <- list_fun.() do
      live = Enum.find(agents, &(&1["name"] == name and is_nil(&1["archived_at"])))
      name_match = Enum.find(agents, &(&1["name"] == name))

      cond do
        live -> {:ok, %{agent_id: live["id"], name: name, digest: digest}}
        name_match -> {:error, {:agent_archived, name}}
        true -> {:error, {:agent_name_conflict, name}}
      end
    end
  end

  # normalize_or_miss/atomize_handle/store_* filled in Task 4; minimal forms here
  # so ensure_agent compiles and the happy path works.
  defp normalize_or_miss(%{agent_id: _, name: _, digest: _} = h), do: {:ok, h}
  defp normalize_or_miss(_other), do: :miss

  defp store_get(mod, sopts, key) do
    mod.get(sopts, key)
  rescue
    _ -> :miss
  end

  defp store_put(mod, sopts, key, value) do
    mod.put(sopts, key, value)
  rescue
    _ -> :ok
  end
end
