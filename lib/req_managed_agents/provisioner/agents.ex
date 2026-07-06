defmodule ReqManagedAgents.Provisioner.Agents do
  @moduledoc """
  Agents as content-addressed managed entities: keyed by spec digest, created
  once, reused forever, superseded by NEW specs, destroyed only by explicit
  prune — the exact lifecycle `Provisioner.Environments` gives environments.

  The provider-side name is `<base>_<digest8>`, so a name collision can only
  mean "this exact agent already exists", and recovery by name is version-correct
  even with an empty store.
  """
  require Logger
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
    case list_fun.() do
      {:ok, %{"data" => agents}} ->
        live = Enum.find(agents, &(&1["name"] == name and is_nil(&1["archived_at"])))
        name_match = Enum.find(agents, &(&1["name"] == name))

        cond do
          live -> {:ok, %{agent_id: live["id"], name: name, digest: digest}}
          name_match -> {:error, {:agent_archived, name}}
          true -> {:error, {:agent_name_conflict, name}}
        end

      other ->
        {:error, {:unexpected_list_response, other}}
    end
  end

  # Store.File round-trips handles through JSON (string keys) — re-atomize the
  # three known fields so callers get one shape from either store. Anything else
  # is a miss and rebuilt: provisioning truth beats cache truth (loud-but-safe).
  defp normalize_or_miss(%{agent_id: _, name: _, digest: _} = h), do: {:ok, h}

  defp normalize_or_miss(%{"agent_id" => id, "name" => n, "digest" => d}),
    do: {:ok, %{agent_id: id, name: n, digest: d}}

  defp normalize_or_miss(other) do
    Logger.warning("agent store entry has unexpected shape, treating as miss: #{inspect(other)}")
    :miss
  end

  defp atomize_handle(%{agent_id: _} = h), do: h

  defp atomize_handle(%{"agent_id" => id, "name" => n, "digest" => d}),
    do: %{agent_id: id, name: n, digest: d}

  @doc "Point `base:tag` at an agent digest (or a handle's digest). Movable; tagged digests survive prune."
  @spec tag_agent(String.t(), String.t(), map() | String.t(), keyword()) :: :ok
  def tag_agent(base, tag, digest_or_handle, opts \\ []) do
    {smod, sopts} = opts[:store] || @default_store
    digest = to_digest(digest_or_handle)

    registry =
      case store_get(smod, sopts, "tags:agent:" <> base) do
        {:ok, %{} = reg} -> reg
        _ -> %{}
      end

    smod.put(sopts, "tags:agent:" <> base, Map.put(registry, tag, digest))
  end

  @doc """
  Resolve `"base:tag"` to the tagged agent's handle. `{:error, :unknown_tag}`
  when the tag is absent, `{:error, {:untracked_digest, d}}` when its digest has
  no provision entry (re-`ensure_agent` to heal). Split is on the FIRST colon only.
  """
  @spec resolve_agent(String.t(), keyword()) ::
          {:ok, map()} | {:error, :unknown_tag} | {:error, {:untracked_digest, String.t()}}
  def resolve_agent(ref, opts \\ []) do
    {smod, sopts} = opts[:store] || @default_store

    {base, tag} =
      case String.split(ref, ":", parts: 2) do
        [base, tag] -> {base, tag}
        _ -> raise ArgumentError, "resolve_agent/2 requires \"base:tag\", got: #{inspect(ref)}"
      end

    with {:ok, %{} = registry} <- store_get(smod, sopts, "tags:agent:" <> base),
         {:tag, digest} when is_binary(digest) <- {:tag, registry[tag]},
         {:handle, _d, {:ok, handle}} <- {:handle, digest, find_handle(smod, sopts, base, digest)} do
      {:ok, atomize_handle(handle)}
    else
      {:tag, nil} -> {:error, :unknown_tag}
      {:handle, digest, :miss} -> {:error, {:untracked_digest, digest}}
      _ -> {:error, :unknown_tag}
    end
  end

  defp find_handle(smod, sopts, base, digest),
    do: store_get(smod, sopts, "digest:agent:" <> base <> ":" <> digest)

  defp to_digest(%{digest: d}), do: d
  defp to_digest(%{"digest" => d}), do: d
  defp to_digest(d) when is_binary(d), do: d

  @doc """
  Explicit GC: archives `<base>_*` agent versions beyond the newest `keep:`
  (REQUIRED), never touching tagged digests or already-archived versions.
  """
  @spec prune_agents(term(), String.t(), keyword()) ::
          {:ok, %{archived: [String.t()], kept: [String.t()]}}
          | {:error, :keep_required | {:partial, [String.t()], {String.t(), term()}}}
  def prune_agents(client, base, opts \\ []) do
    case opts[:keep] do
      keep when is_integer(keep) and keep > 0 -> do_prune(client, base, keep, opts)
      _ -> {:error, :keep_required}
    end
  end

  defp do_prune(client, base, keep, opts) do
    {smod, sopts} = opts[:store] || @default_store
    list_fun = opts[:list_fun] || fn -> ReqManagedAgents.Client.list_agents(client, %{}) end

    archive_fun =
      opts[:archive_fun] || fn id -> ReqManagedAgents.Client.archive_agent(client, id) end

    tagged =
      case store_get(smod, sopts, "tags:agent:" <> base) do
        {:ok, reg} -> reg |> Map.values() |> MapSet.new()
        _ -> MapSet.new()
      end

    case list_fun.() do
      {:ok, %{"data" => agents}} ->
        {kept_by_count, candidates} = agents |> live_versions(base) |> Enum.split(keep)
        {tagged_keeps, to_archive} = Enum.split_with(candidates, &tagged?(&1, tagged, base))
        kept = Enum.map(kept_by_count ++ tagged_keeps, & &1["name"])
        # Archive oldest-first so a partial failure preserves the newest history.
        archive_all(Enum.reverse(to_archive), archive_fun, smod, sopts, base, kept, [])

      other ->
        {:error, {:unexpected_list_response, other}}
    end
  end

  # Live (non-archived) versions of THIS base, newest first. Membership is
  # strict — the prefix strips and the remaining suffix is exactly a digest8 —
  # so base "data" can never sweep in base "data_analysis"'s versions.
  defp live_versions(agents, base) do
    prefix = base <> "_"

    agents
    |> Enum.filter(fn a ->
      suffix = String.replace_prefix(a["name"], prefix, "")

      suffix != a["name"] and String.match?(suffix, ~r/^[0-9a-f]{8}$/) and
        is_nil(a["archived_at"])
    end)
    |> Enum.sort_by(& &1["created_at"], :desc)
  end

  defp tagged?(a, tagged, base),
    do: MapSet.member?(tagged, String.replace_prefix(a["name"], base <> "_", ""))

  defp archive_all([], _fun, _smod, _sopts, _base, kept, archived),
    do: {:ok, %{archived: Enum.reverse(archived), kept: kept}}

  defp archive_all([a | rest], fun, smod, sopts, base, kept, archived) do
    case fun.(a["id"]) do
      {:ok, _} ->
        digest = String.replace_prefix(a["name"], base <> "_", "")
        smod.delete(sopts, "digest:agent:" <> base <> ":" <> digest)

        # Values may be stored JSON-normalized (Store.File) or as-written (ETS); delete both shapes.
        smod.delete_value(sopts, %{agent_id: a["id"], name: a["name"], digest: digest})

        smod.delete_value(sopts, %{
          "agent_id" => a["id"],
          "name" => a["name"],
          "digest" => digest
        })

        archive_all(rest, fun, smod, sopts, base, kept, [a["name"] | archived])

      {:error, reason} ->
        {:error, {:partial, Enum.reverse(archived), {a["name"], reason}}}
    end
  end

  defp store_get(mod, sopts, key) do
    mod.get(sopts, key)
  rescue
    e ->
      Logger.warning("agent store get failed (treating as miss): #{inspect(e)}")
      :miss
  end

  defp store_put(mod, sopts, key, value) do
    mod.put(sopts, key, value)
  rescue
    e -> Logger.warning("agent store put failed (handle still returned): #{inspect(e)}")
  end
end
