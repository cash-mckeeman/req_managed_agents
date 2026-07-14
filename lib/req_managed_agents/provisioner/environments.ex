defmodule ReqManagedAgents.Provisioner.Environments do
  @moduledoc """
  Environments as immutable images: content-addressed by spec digest, built
  once, reused forever, superseded by NEW images (never mutated), destroyed
  only by explicit prune.

  The provider-side name is `<base>_<digest8>` — `repo@digest` — so a name
  collision can only ever mean "this exact image already exists", and recovery
  by name is definitionally version-correct even with an empty store.
  """
  require Logger
  alias ReqManagedAgents.Environment
  alias ReqManagedAgents.Provisioner
  alias ReqManagedAgents.Provisioner.Environment.Handle
  alias ReqManagedAgents.Provisioner.Runtimes
  alias ReqManagedAgents.Provisioner.Store

  @default_store {Store.ETS, :req_managed_agents_provisions}

  @doc """
  Build-if-absent for an environment image. Returns `{:ok, %Handle{}}`.

  When the spec declares runtimes, the RETURNED `%Handle{}` additionally
  carries `bootstrap: %{script: ..., instructions: ...}` — DERIVED from the
  spec on every call (all paths: fresh create, recovery, store hit), never
  stored. The persisted handle stays exactly three fields (`bootstrap` is
  excluded from the `Jason.Encoder` derivation); only the in-memory struct
  returned here carries it. Sessions execute the script via the agent's bash
  on first need; the library only renders it.

  Opts: `:name` (repository base, default `"env"`), `:store`
  (`{module, store_opts}`), `:create_fun` / `:list_fun` (test seams; default
  to `ReqManagedAgents.Client` calls on the given client).
  """
  @spec ensure_environment(term(), Environment.Spec.t() | map(), keyword()) ::
          {:ok, Handle.t()} | {:error, term()}
  def ensure_environment(client, env_spec, opts \\ []) do
    with {:ok, env} <- Environment.Spec.new(env_spec) do
      with {:ok, handle} <- do_ensure_environment(client, env, opts) do
        {:ok, attach_bootstrap(handle, env.runtimes)}
      end
    end
  end

  # Bootstrap is a derived view of the spec, recomputed per call — the stored
  # handle shape is frozen at three fields (bootstrap is excluded from the
  # Jason.Encoder derivation), so caches never go stale on template changes.
  # The return stays a %Handle{} on every path — bootstrap is a struct field,
  # never a downgrade to a plain map.
  defp attach_bootstrap(handle, []), do: handle

  defp attach_bootstrap(%Handle{} = handle, runtimes) do
    %{
      handle
      | bootstrap: %{
          script: Runtimes.bootstrap_script(runtimes),
          instructions: Runtimes.system_prompt_block(runtimes)
        }
    }
  end

  defp do_ensure_environment(client, %Environment.Spec{} = env, opts) do
    base = opts[:name] || "env"
    digest = env |> Environment.Spec.digest() |> binary_part(0, 8) |> String.downcase()
    name = base <> "_" <> digest
    {smod, sopts} = opts[:store] || @default_store
    key = "provision:env:" <> Provisioner.hash({base, digest})
    digest_key = "digest:" <> base <> ":" <> digest

    create_fun =
      opts[:create_fun] ||
        fn body -> ReqManagedAgents.Client.create_environment(client, body) end

    list_fun =
      opts[:list_fun] || fn -> ReqManagedAgents.Client.list_environments(client, %{}) end

    with {:ok, stored} <- store_get(smod, sopts, key),
         {:ok, handle} <- normalize_or_miss(stored) do
      {:ok, handle}
    else
      :miss ->
        case build(create_fun, list_fun, env, name, digest) do
          {:ok, handle} ->
            store_put(smod, sopts, key, handle)
            store_put(smod, sopts, digest_key, handle)
            {:ok, handle}

          error ->
            error
        end
    end
  end

  @doc """
  Point `base:tag` at an image digest (or a handle's digest). A movable
  pointer — retagging replaces it. Tagged digests are protected from `prune/3`.
  """
  def tag(base, tag, digest_or_handle, opts \\ []) do
    {smod, sopts} = opts[:store] || @default_store
    digest = to_digest(digest_or_handle)

    # read-modify-write: single-writer store assumption (see Store.File moduledoc)
    registry =
      case store_get(smod, sopts, "tags:" <> base) do
        {:ok, %{} = reg} -> reg
        _ -> %{}
      end

    smod.put(sopts, "tags:" <> base, Map.put(registry, tag, digest))
  end

  @doc """
  Resolve `"base:tag"` to the tagged image's handle. Never falls back:
  `{:error, :unknown_tag}` when the tag doesn't exist,
  `{:error, {:untracked_digest, digest}}` when the tag points at a digest whose
  provision entry is gone (e.g. pruned store) — re-`ensure` the spec to heal.

  `ref` must be of the form `"base:tag"` — a ref without a colon raises `ArgumentError`.
  The split is on the FIRST colon only, so tag names may themselves contain
  colons (`"a:b:c"` resolves tag `"b:c"` under base `"a"`).

  The resolved handle's `:bootstrap` is always `nil` — no env spec is in
  scope here to derive it from; call `ensure_environment/3` with the spec
  when the bootstrap content is needed.
  """
  def resolve(ref, opts \\ []) do
    {smod, sopts} = opts[:store] || @default_store

    {base, tag} =
      case String.split(ref, ":", parts: 2) do
        [base, tag] ->
          {base, tag}

        _ ->
          raise ArgumentError,
                "resolve/2 requires a ref of the form \"base:tag\", got: #{inspect(ref)}"
      end

    with {:ok, %{} = registry} <- store_get(smod, sopts, "tags:" <> base),
         {:tag, digest} when is_binary(digest) <- {:tag, registry[tag]},
         {:handle, _digest, {:ok, handle}} <-
           {:handle, digest, find_handle(smod, sopts, base, digest)} do
      {:ok, Handle.new(handle)}
    else
      {:tag, nil} -> {:error, :unknown_tag}
      {:handle, digest, :miss} -> {:error, {:untracked_digest, digest}}
      # :miss registry, corrupt registry ({:ok, non-map} / {:tag, non-binary})
      _ -> {:error, :unknown_tag}
    end
  end

  @doc """
  Explicit image GC: archives `<base>_*` environment versions beyond the newest
  `keep:` (REQUIRED — there is no default for a permanent operation), never
  touching tagged digests or already-archived versions. Returns
  `{:ok, %{archived: names, kept: names}}` or
  `{:error, {:partial, archived_names, {failed_name, reason}}}`.
  """
  def prune_environments(client, base, opts \\ []) do
    case opts[:keep] do
      keep when is_integer(keep) and keep > 0 -> do_prune(client, base, keep, opts)
      _ -> {:error, :keep_required}
    end
  end

  defp do_prune(client, base, keep, opts) do
    {smod, sopts} = opts[:store] || @default_store

    list_fun =
      opts[:list_fun] || fn -> ReqManagedAgents.Client.list_environments(client, %{}) end

    archive_fun =
      opts[:archive_fun] || fn id -> ReqManagedAgents.Client.archive_environment(client, id) end

    tagged =
      case store_get(smod, sopts, "tags:" <> base) do
        {:ok, reg} -> reg |> Map.values() |> MapSet.new()
        _ -> MapSet.new()
      end

    with {:ok, %{"data" => envs}} <- list_fun.() do
      {kept_by_count, candidates} = envs |> live_versions(base) |> Enum.split(keep)
      {tagged_keeps, to_archive} = Enum.split_with(candidates, &tagged?(&1, tagged, base))
      kept = Enum.map(kept_by_count ++ tagged_keeps, & &1["name"])
      # Archive oldest-first so a partial failure preserves the newest history.
      archive_all(Enum.reverse(to_archive), archive_fun, smod, sopts, base, kept, [])
    end
  end

  # Live (non-archived) versions of THIS base, newest first. Membership is
  # strict — the prefix strips and the remaining suffix is exactly a digest8 —
  # so base "data" can never sweep in base "data_analysis"'s versions.
  defp live_versions(envs, base) do
    prefix = base <> "_"

    envs
    |> Enum.filter(fn e ->
      suffix = String.replace_prefix(e["name"], prefix, "")

      suffix != e["name"] and String.match?(suffix, ~r/^[0-9a-f]{8}$/) and
        is_nil(e["archived_at"])
    end)
    |> Enum.sort_by(& &1["created_at"], :desc)
  end

  defp tagged?(e, tagged, base),
    do: MapSet.member?(tagged, String.replace_prefix(e["name"], base <> "_", ""))

  defp archive_all([], _fun, _smod, _sopts, _base, kept, archived),
    do: {:ok, %{archived: Enum.reverse(archived), kept: kept}}

  defp archive_all([e | rest], fun, smod, sopts, base, kept, archived) do
    case fun.(e["id"]) do
      {:ok, _} ->
        digest = String.replace_prefix(e["name"], base <> "_", "")
        smod.delete(sopts, "digest:" <> base <> ":" <> digest)

        # Values may be stored JSON-normalized (Store.File, string keys) or as-written
        # (ETS, the exact %Handle{} struct); delete both shapes.
        smod.delete_value(
          sopts,
          Handle.new(%{environment_id: e["id"], name: e["name"], digest: digest})
        )

        smod.delete_value(sopts, %{
          "environment_id" => e["id"],
          "name" => e["name"],
          "digest" => digest
        })

        archive_all(rest, fun, smod, sopts, base, kept, [e["name"] | archived])

      {:error, reason} ->
        {:error, {:partial, Enum.reverse(archived), {e["name"], reason}}}
    end
  end

  defp find_handle(smod, sopts, base, digest) do
    # Provision entries are keyed by full spec hash; the handle carries the
    # digest — scan is not possible via the 4-callback store, so handles are
    # ALSO indexed at ensure time. The index is BASE-scoped ("digest:<base>:<d>")
    # because the digest hashes only the spec: two bases sharing a spec share a
    # digest, and an unscoped index would let resolve return the wrong base's env.
    store_get(smod, sopts, "digest:" <> base <> ":" <> digest)
  end

  defp to_digest(%{digest: d}), do: d
  defp to_digest(%{"digest" => d}), do: d
  defp to_digest(d) when is_binary(d), do: d

  defp build(create_fun, list_fun, %Environment.Spec{} = env, name, digest) do
    body = %{name: name, config: wire_config(env)}

    case create_fun.(body) do
      {:ok, %{"id" => id}} ->
        {:ok, Handle.new(%{environment_id: id, name: name, digest: digest})}

      {:error, {:http_error, 409, _}} ->
        recover(list_fun, name, digest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recover(list_fun, name, digest) do
    with {:ok, %{"data" => envs}} <- list_fun.() do
      live = Enum.find(envs, &(&1["name"] == name and is_nil(&1["archived_at"])))
      name_match = Enum.find(envs, &(&1["name"] == name))

      cond do
        live -> {:ok, Handle.new(%{environment_id: live["id"], name: name, digest: digest})}
        name_match -> {:error, {:environment_archived, name}}
        true -> {:error, {:environment_name_conflict, name}}
      end
    end
  end

  # `config` is provider-verbatim and opaque beyond hashing — `runtimes` lives
  # on the struct, never inside `config`, so it can never leak to the wire
  # (library vocabulary — realized client-side via the bootstrap, already
  # covered by the digest; providers must not receive keys they can't know).
  # When runtimes are declared with `:limited`/`"limited"` networking, required
  # runtime hosts are merged into `config.networking.allowed_hosts` (deduped,
  # order preserved).
  defp wire_config(%Environment.Spec{runtimes: runtimes, config: config}) do
    networking = config[:networking]

    if runtimes != [] and limited_networking?(networking) do
      merge_runtime_hosts(config, runtimes, networking)
    else
      config
    end
  end

  defp limited_networking?(%{type: type}) when type in [:limited, "limited"], do: true
  defp limited_networking?(%{"type" => type}) when type in [:limited, "limited"], do: true
  defp limited_networking?(_), do: false

  defp merge_runtime_hosts(config, runtimes, networking) do
    required = Runtimes.required_hosts(runtimes)

    existing =
      Map.get(networking, :allowed_hosts) || Map.get(networking, "allowed_hosts") || []

    merged = Enum.uniq(existing ++ required)

    # Write back under the key form the networking map already uses.
    hosts_key = if Map.has_key?(networking, "type"), do: "allowed_hosts", else: :allowed_hosts
    Map.put(config, :networking, Map.put(networking, hosts_key, merged))
  end

  # Store.File round-trips handles through JSON (string keys) — Handle.new/1
  # absorbs both the atom-keyed (fresh) and string-keyed (post-round-trip)
  # shapes into one struct. Anything else (foreign store content, missing
  # keys) is treated as a miss and rebuilt: provisioning truth beats cache
  # truth (loud-but-safe).
  defp normalize_or_miss(%{environment_id: _, name: _, digest: _} = h), do: {:ok, Handle.new(h)}

  defp normalize_or_miss(%{"environment_id" => _, "name" => _, "digest" => _} = h),
    do: {:ok, Handle.new(h)}

  defp normalize_or_miss(other) do
    Logger.warning(
      "environment store entry has unexpected shape, treating as miss: #{inspect(other)}"
    )

    :miss
  end

  defp store_get(mod, sopts, key) do
    mod.get(sopts, key)
  rescue
    e ->
      Logger.warning("environment store get failed (treating as miss): #{inspect(e)}")
      :miss
  end

  defp store_put(mod, sopts, key, value) do
    mod.put(sopts, key, value)
  rescue
    e -> Logger.warning("environment store put failed (handle still returned): #{inspect(e)}")
  end
end
