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
  alias ReqManagedAgents.Provisioner
  alias ReqManagedAgents.Provisioner.Store

  @default_store {Store.ETS, :req_managed_agents_provisions}

  @doc """
  Build-if-absent for an environment image. Returns
  `{:ok, %{environment_id: id, name: name, digest: digest}}`.

  Opts: `:name` (repository base, default `"env"`), `:store`
  (`{module, store_opts}`), `:create_fun` / `:list_fun` (test seams; default
  to `ReqManagedAgents.Client` calls on the given client).
  """
  def ensure_environment(client, env_spec, opts \\ []) do
    base = opts[:name] || "env"
    digest = env_spec |> Provisioner.hash() |> binary_part(0, 8) |> String.downcase()
    name = base <> "_" <> digest
    {smod, sopts} = opts[:store] || @default_store
    key = "provision:env:" <> Provisioner.hash({base, env_spec})
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
        case build(create_fun, list_fun, env_spec, name, digest) do
          {:ok, handle} ->
            store_put(smod, sopts, key, handle)
            store_put(smod, sopts, digest_key, handle)
            {:ok, handle}

          error ->
            error
        end
    end
  end

  defp build(create_fun, list_fun, env_spec, name, digest) do
    body = %{name: name, config: wire_config(env_spec)}

    case create_fun.(body) do
      {:ok, %{"id" => id}} ->
        {:ok, %{environment_id: id, name: name, digest: digest}}

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
        live -> {:ok, %{environment_id: live["id"], name: name, digest: digest}}
        name_match -> {:error, {:environment_archived, name}}
        true -> {:error, {:environment_name_conflict, name}}
      end
    end
  end

  # The env spec is opaque beyond hashing; the wire `config` is the spec minus
  # our own bookkeeping keys (currently none to strip — pass through).
  defp wire_config(env_spec), do: env_spec

  # Store.File round-trips handles through JSON (string keys) — re-atomize the
  # three known fields so callers get one shape from either store. Anything
  # else (foreign store content, missing keys) is treated as a miss and
  # rebuilt: provisioning truth beats cache truth (loud-but-safe).
  defp normalize_or_miss(%{environment_id: _} = h), do: {:ok, h}

  defp normalize_or_miss(%{"environment_id" => id, "name" => n, "digest" => d}),
    do: {:ok, %{environment_id: id, name: n, digest: d}}

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
