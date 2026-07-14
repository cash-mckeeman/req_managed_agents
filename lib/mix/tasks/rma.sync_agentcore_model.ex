defmodule Mix.Tasks.Rma.SyncAgentcoreModel do
  @shortdoc "Sync the bedrock-agentcore botocore model into the private conformance corpus"
  @moduledoc """
  Maintainer task: mirrors the `bedrock-agentcore` and `bedrock-agentcore-control`
  botocore `service-2.json` models from `boto/botocore` into
  `$RMA_CORPUS_DIR/agentcore/model/`, and pins the upstream commit plus
  per-file SHA256 in `$RMA_CORPUS_DIR/agentcore/manifest.json`.

  Not shipped in the hex package (`lib/mix` is excluded from `package.files`)
  and not exercised by CI — only `changeset/2` is unit-tested. Requires
  `RMA_CORPUS_DIR` (the private conformance corpus checkout):

      RMA_CORPUS_DIR=/path/to/corpus mix rma.sync_agentcore_model

  Exit codes: 0 = model already up to date; 2 = model was updated (drift
  signal for a maintainer CI job); 1 = task failure. Requires OTP 25+
  (verified TLS via `:public_key.cacerts_get/0`). Set `GITHUB_TOKEN` for API
  rate-limit headroom.
  """
  use Mix.Task

  # :public_key is loaded at runtime via Mix.ensure_application!/1 — it is
  # deliberately NOT in the library's application spec (maintainer-only task).
  @compile {:no_warn_undefined, :public_key}

  @repo "boto/botocore"
  # botocore's default branch is `develop`, not `main` — it has no `main` branch,
  # so `commits/main` 422s and the whole sync dies on its first API call. Pin the
  # real default branch here (used for both the tip lookup and the manifest ref).
  @ref "develop"
  @data_path "botocore/data"
  @services ["bedrock-agentcore", "bedrock-agentcore-control"]

  @impl Mix.Task
  def run(_argv) do
    model_dir = corpus_agentcore_dir() |> Path.join("model")
    manifest_path = corpus_agentcore_dir() |> Path.join("manifest.json")

    {sha, fetched} = fetch()
    local = local_manifest(manifest_path)
    cs = changeset(fetched, local)

    if cs == %{added: [], changed: [], removed: []} do
      Mix.shell().info("model up to date with #{@repo}@#{String.slice(sha, 0, 12)} (no changes)")
    else
      old_sha = get_in(local, ["source", "commit"])
      apply_sync(fetched, cs, sha, model_dir, manifest_path)
      Mix.shell().info(summary(cs, old_sha, sha))
      exit({:shutdown, 2})
    end
  end

  # Resolves the maintainer-only conformance corpus's agentcore dir directly
  # from RMA_CORPUS_DIR, without depending on the test-only
  # ReqManagedAgents.Conformance.Corpus module (test/support is not compiled
  # in :dev, where this task normally runs).
  defp corpus_agentcore_dir do
    System.fetch_env!("RMA_CORPUS_DIR") |> Path.join("agentcore")
  end

  @doc false
  @spec fetch() :: {String.t(), %{optional(String.t()) => binary()}}
  def fetch do
    Mix.ensure_application!(:inets)
    Mix.ensure_application!(:ssl)
    Mix.ensure_application!(:public_key)
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    sha =
      api!("/repos/#{@repo}/commits/#{@ref}")
      |> Map.fetch!("sha")

    service_dirs = discover_service_dirs(sha)

    fetched =
      for dir <- service_dirs,
          path <- list_files(sha, dir),
          into: %{} do
        rel = Path.relative_to(path, @data_path)
        {rel, get!("https://raw.githubusercontent.com/#{@repo}/#{sha}/#{path}", [])}
      end

    if fetched == %{} do
      Mix.raise("upstream botocore listing came back empty for #{inspect(@services)}@#{sha}")
    end

    {sha, fetched}
  end

  # Discovers the exact <service>/<version>/ dirs under botocore/data, since
  # the version segment (e.g. "2023-06-11") isn't knowable ahead of time and
  # the GitHub contents API has no glob support.
  defp discover_service_dirs(sha) do
    case api!("/repos/#{@repo}/contents/#{@data_path}?ref=#{sha}") do
      entries when is_list(entries) ->
        matches =
          for %{"type" => "dir", "name" => name, "path" => path} <- entries,
              name in @services,
              do: path

        missing = @services -- Enum.map(matches, &Path.basename/1)

        if missing != [] do
          Mix.raise(
            "expected botocore service dir(s) not found under #{@data_path}: #{inspect(missing)}"
          )
        end

        matches

      other ->
        Mix.raise("unexpected contents response for #{@data_path}: #{inspect(other)}")
    end
  end

  defp list_files(sha, path) do
    case api!("/repos/#{@repo}/contents/#{path}?ref=#{sha}") do
      entries when is_list(entries) ->
        Enum.flat_map(entries, fn
          %{"type" => "file", "path" => p} -> [p]
          %{"type" => "dir", "path" => p} -> list_files(sha, p)
          other -> Mix.raise("unexpected contents entry under #{path}: #{inspect(other)}")
        end)

      other ->
        Mix.raise("unexpected contents response for #{path}: #{inspect(other)}")
    end
  end

  defp api!(path) do
    auth =
      case System.get_env("GITHUB_TOKEN") do
        nil -> []
        token -> [{"authorization", "Bearer #{token}"}]
      end

    headers = [{"accept", "application/vnd.github+json"} | auth]

    ("https://api.github.com" <> path)
    |> get!(headers)
    |> Jason.decode!()
  end

  defp get!(url, headers) do
    headers = [{"user-agent", "req_managed_agents agentcore model sync (mix task)"} | headers]

    request =
      {String.to_charlist(url),
       Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}

    ssl_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    http_opts = [ssl: ssl_opts, timeout: 30_000, connect_timeout: 10_000, autoredirect: false]

    case :httpc.request(:get, request, http_opts, body_format: :binary) do
      {:ok, {{_http, 200, _status}, _resp_headers, body}} ->
        body

      {:ok, {{_http, code, status}, _resp_headers, body}} ->
        Mix.raise("GET #{url} -> #{code} #{status}: #{String.slice(body, 0, 200)}")

      {:error, reason} ->
        Mix.raise("GET #{url} failed: #{inspect(reason)}")
    end
  end

  @doc """
  Compares fetched upstream content against a locally recorded manifest and
  reports which paths are new, changed (SHA256 mismatch), or gone. Pure —
  does no I/O, so it's unit-testable without network access.
  """
  @spec changeset(%{optional(String.t()) => binary()}, map()) :: %{
          added: [String.t()],
          changed: [String.t()],
          removed: [String.t()]
        }
  def changeset(fetched, local) when is_map(fetched) and is_map(local) do
    local_files = Map.get(local, "files", %{})
    local_paths = local_files |> Map.keys() |> MapSet.new()
    fetched_paths = fetched |> Map.keys() |> MapSet.new()

    changed =
      for path <- MapSet.intersection(local_paths, fetched_paths),
          sha256(Map.fetch!(fetched, path)) != Map.fetch!(local_files, path),
          do: path

    %{
      added: MapSet.difference(fetched_paths, local_paths) |> Enum.sort(),
      changed: Enum.sort(changed),
      removed: MapSet.difference(local_paths, fetched_paths) |> Enum.sort()
    }
  end

  @doc false
  @spec apply_sync(
          %{optional(String.t()) => binary()},
          %{added: [String.t()], changed: [String.t()], removed: [String.t()]},
          String.t(),
          String.t(),
          String.t()
        ) :: :ok
  def apply_sync(fetched, cs, commit_sha, model_dir, manifest_path) do
    File.mkdir_p!(model_dir)

    for path <- cs.added ++ cs.changed do
      dest = Path.join(model_dir, path)
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, Map.fetch!(fetched, path))
    end

    for path <- cs.removed, do: File.rm!(Path.join(model_dir, path))

    File.write!(manifest_path, manifest_json(fetched, commit_sha))
    :ok
  end

  @doc false
  @spec manifest_json(%{optional(String.t()) => binary()}, String.t()) :: String.t()
  def manifest_json(fetched, commit_sha) do
    files = for {path, bin} <- Enum.sort(fetched), do: {path, sha256(bin)}

    source = [
      {"repo", @repo},
      {"path", @data_path},
      {"services", @services},
      {"ref", @ref},
      {"commit", commit_sha}
    ]

    %Jason.OrderedObject{
      values: [
        {"source", %Jason.OrderedObject{values: source}},
        {"files", %Jason.OrderedObject{values: files}}
      ]
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp sha256(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  defp local_manifest(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, map} <- Jason.decode(raw) do
      map
    else
      _ -> %{}
    end
  end

  @doc false
  def summary(%{added: added, changed: changed, removed: removed}, old_sha, new_sha) do
    lines =
      Enum.map(added, &"  added:   #{&1}") ++
        Enum.map(changed, &"  changed: #{&1}") ++
        Enum.map(removed, &"  removed: #{&1}")

    header = "botocore model changed (#{@repo} #{short(old_sha)} -> #{short(new_sha)}):"

    compare =
      if old_sha,
        do: ["compare: https://github.com/#{@repo}/compare/#{old_sha}...#{new_sha}"],
        else: []

    Enum.join([header | lines] ++ compare, "\n")
  end

  defp short(nil), do: "(none)"
  defp short(sha), do: String.slice(sha, 0, 12)
end
