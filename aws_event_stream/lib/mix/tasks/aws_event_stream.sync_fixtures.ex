defmodule Mix.Tasks.AwsEventStream.SyncFixtures do
  @shortdoc "Sync test/fixtures/aws_sdk_go_v2 from the upstream aws-sdk-go-v2 corpus"
  @moduledoc """
  Maintainer task: mirrors `aws/aws-sdk-go-v2:aws/protocol/eventstream/testdata`
  into `test/fixtures/aws_sdk_go_v2/` and pins the upstream commit in
  `manifest.json`.

  Exit codes: 0 = fixtures already up to date; 2 = fixtures were updated
  (CI drift signal); 1 = task failure. Requires OTP 25+ (verified TLS via
  `:public_key.cacerts_get/0`). Set `GITHUB_TOKEN` for API rate-limit headroom.

  Not shipped in the hex package.
  """
  use Mix.Task

  # :public_key is loaded at runtime via Mix.ensure_application!/1 — it is
  # deliberately NOT in the library's application spec (maintainer-only task).
  @compile {:no_warn_undefined, :public_key}

  @repo "aws/aws-sdk-go-v2"
  @upstream_path "aws/protocol/eventstream/testdata"
  @corpus_dir "test/fixtures/aws_sdk_go_v2"

  @impl Mix.Task
  def run(_argv) do
    {sha, fetched} = fetch()
    changeset = changeset(fetched, @corpus_dir)

    if changeset == %{added: [], changed: [], removed: []} do
      Mix.shell().info(
        "fixtures up to date with #{@repo}@#{String.slice(sha, 0, 12)} (no changes)"
      )
    else
      old_sha = local_manifest_commit(@corpus_dir)
      apply_sync(fetched, changeset, sha, @corpus_dir)
      Mix.shell().info(summary(changeset, old_sha, sha))
      exit({:shutdown, 2})
    end
  end

  @doc false
  def fetch do
    Mix.ensure_application!(:inets)
    Mix.ensure_application!(:ssl)
    Mix.ensure_application!(:public_key)
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    sha =
      api!("/repos/#{@repo}/commits/main")
      |> Map.fetch!("sha")

    paths = list_files(sha, @upstream_path)

    fetched =
      for path <- paths, into: %{} do
        rel = Path.relative_to(path, @upstream_path)
        {rel, get!("https://raw.githubusercontent.com/#{@repo}/#{sha}/#{path}", [])}
      end

    # never let an upstream file collide with our generated manifest
    fetched = Map.delete(fetched, "manifest.json")

    if fetched == %{} do
      Mix.raise("upstream corpus listing came back empty — #{@repo}:#{@upstream_path}@#{sha}")
    end

    {sha, fetched}
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
    headers = [{"user-agent", "aws_event_stream fixture sync (mix task)"} | headers]

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

  @doc false
  def changeset(fetched, dir) do
    local = local_files(dir)
    fetched_paths = fetched |> Map.keys() |> MapSet.new()

    changed =
      for path <- MapSet.intersection(local, fetched_paths),
          File.read!(Path.join(dir, path)) != Map.fetch!(fetched, path),
          do: path

    %{
      added: MapSet.difference(fetched_paths, local) |> Enum.sort(),
      changed: Enum.sort(changed),
      removed: MapSet.difference(local, fetched_paths) |> Enum.sort()
    }
  end

  @doc false
  def apply_sync(fetched, changeset, commit_sha, dir) do
    File.mkdir_p!(dir)

    for path <- changeset.added ++ changeset.changed do
      dest = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, Map.fetch!(fetched, path))
    end

    for path <- changeset.removed, do: File.rm!(Path.join(dir, path))

    File.write!(Path.join(dir, "manifest.json"), manifest_json(fetched, commit_sha))
    :ok
  end

  @doc false
  def manifest_json(fetched, commit_sha) do
    files =
      for {path, bin} <- Enum.sort(fetched) do
        {path, Base.encode16(:crypto.hash(:sha256, bin), case: :lower)}
      end

    source = [
      {"repo", @repo},
      {"path", @upstream_path},
      {"ref", "main"},
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

  @doc false
  def local_manifest_commit(dir) do
    with {:ok, bin} <- File.read(Path.join(dir, "manifest.json")),
         {:ok, %{"source" => %{"commit" => sha}}} <- Jason.decode(bin) do
      sha
    else
      _ -> nil
    end
  end

  @doc false
  def summary(%{added: added, changed: changed, removed: removed}, old_sha, new_sha) do
    lines =
      Enum.map(added, &"  added:   #{&1}") ++
        Enum.map(changed, &"  changed: #{&1}") ++
        Enum.map(removed, &"  removed: #{&1}")

    header = "upstream fixtures changed (#{@repo} #{short(old_sha)} -> #{short(new_sha)}):"

    compare =
      if old_sha,
        do: ["compare: https://github.com/#{@repo}/compare/#{old_sha}...#{new_sha}"],
        else: []

    Enum.join([header | lines] ++ compare, "\n")
  end

  defp short(nil), do: "(none)"
  defp short(sha), do: String.slice(sha, 0, 12)

  defp local_files(dir) do
    if File.dir?(dir) do
      dir
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, dir))
      |> Enum.reject(&(&1 == "manifest.json"))
      |> MapSet.new()
    else
      MapSet.new()
    end
  end
end
