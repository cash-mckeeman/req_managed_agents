defmodule ReqManagedAgents.Conformance.Capture do
  @moduledoc """
  Live-capture harness for the conformance corpus. `attach/2` is a `Req`
  adapter-wrapping step that records the real outbound/inbound bodies of ONE
  named operation into a collector; `write_pair/5` is the pure writer that
  redacts and persists a captured request/response pair into the corpus.

  Test-only (`test/support`, not compiled in `:dev`/`:prod`). `write_pair/5`
  is the shipped/tested surface — it takes `captured_at` as a parameter
  (never `DateTime.utc_now/0` itself) so it stays deterministic and
  unit-testable without the network. `mix rma.capture` (`lib/`) cannot depend
  on this module — see that task's moduledoc for why — and duplicates the
  minimal redact-and-write logic inline; keep the two in sync by hand.
  """

  alias ReqManagedAgents.Conformance.{Corpus, Redaction}

  @collector __MODULE__.Collector

  @doc "Starts (or reuses) the capture collector. Idempotent; `attach/2`/`fetch/1` call it lazily."
  @spec start_collector() :: {:ok, pid()}
  def start_collector do
    case Agent.start_link(fn -> %{} end, name: @collector) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc """
  A `Req` request-adapter step (`Req.Request`'s `:adapter` option is itself
  documented as "a request step that makes the actual HTTP request"): wraps
  the real adapter, stashing the outbound (already-encoded, post
  `encode_body`) request body and the raw inbound response body under `name`
  for later `fetch/1`, then returns the request/response unchanged so the
  rest of the pipeline — decoding, the caller's own `handle/1` — behaves
  exactly as it would without capture.

  Merge the result into a client's `:req_options`, e.g.
  `Client.new(credentials: creds, req_options: Capture.attach("create_harness"))`.
  """
  @spec attach(String.t() | atom(), keyword()) :: keyword()
  def attach(name, req_options \\ []) do
    real_adapter = req_options[:adapter] || (&Req.Steps.run_finch/1)

    adapter = fn req ->
      {req, result} = real_adapter.(req)
      capture(name, req, result)
      {req, result}
    end

    Keyword.put(req_options, :adapter, adapter)
  end

  defp capture(name, req, %Req.Response{} = resp) do
    start_collector()
    Agent.update(@collector, &Map.put(&1, to_string(name), {decode(req.body), decode(resp.body)}))
  end

  # Transport errors (an Exception, per the adapter contract) are surfaced to the caller as-is;
  # there is nothing captureable.
  defp capture(_name, _req, _not_a_response), do: :ok

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, json} -> json
      _ -> %{}
    end
  end

  defp decode(body) when is_map(body), do: body
  defp decode(_other), do: %{}

  @doc "Retrieves and clears the request/response pair captured under `name` by `attach/2`."
  @spec fetch(String.t() | atom()) :: {:ok, map(), map()} | :error
  def fetch(name) do
    start_collector()

    Agent.get_and_update(@collector, fn state ->
      case Map.pop(state, to_string(name)) do
        {nil, state} -> {:error, state}
        {{req, resp}, state} -> {{:ok, req, resp}, state}
      end
    end)
  end

  @doc """
  Redacts `req_json`/`resp_json` (`Redaction.redact/1`), writes
  `requests/<name>.json` and `responses/<name>.json` under
  `Corpus.dir(surface)`, and stamps/merges `manifest.json` with
  `captured_at` (ISO 8601), `redaction_version`, and each written file's
  relative path + SHA256. `captured_at` is a caller-supplied parameter —
  never computed here — so this function is pure I/O with no clock
  dependency.
  """
  @spec write_pair(atom(), String.t(), map(), map(), DateTime.t()) :: :ok
  def write_pair(surface, name, req_json, resp_json, %DateTime{} = captured_at)
      when is_atom(surface) and is_binary(name) do
    dir = corpus_dir!(surface)

    req_rel = Path.join("requests", "#{name}.json")
    resp_rel = Path.join("responses", "#{name}.json")

    req_sha = write_json!(dir, req_rel, Redaction.redact(req_json))
    resp_sha = write_json!(dir, resp_rel, Redaction.redact(resp_json))

    update_manifest!(dir, captured_at, %{req_rel => req_sha, resp_rel => resp_sha})
    :ok
  end

  # Corpus.dir/1 falls back to the bundled synthetic examples dir when RMA_CORPUS_DIR/<surface>
  # doesn't exist YET — exactly the case on a fresh capture. Create the directory first so that
  # fallback never fires here; captured (redacted) live traffic must never land in the
  # git-tracked examples fixtures.
  defp corpus_dir!(surface) do
    System.fetch_env!("RMA_CORPUS_DIR") |> Path.join(to_string(surface)) |> File.mkdir_p!()
    Corpus.dir(surface)
  end

  defp write_json!(dir, relpath, data) do
    path = Path.join(dir, relpath)
    File.mkdir_p!(Path.dirname(path))
    bytes = Jason.encode!(data, pretty: true) <> "\n"
    File.write!(path, bytes)
    sha256(bytes)
  end

  defp update_manifest!(dir, captured_at, files_delta) do
    path = Path.join(dir, "manifest.json")
    existing = read_manifest(path)

    manifest =
      existing
      |> Map.put("captured_at", DateTime.to_iso8601(captured_at))
      |> Map.put("redaction_version", Redaction.version())
      |> Map.put("files", Map.merge(Map.get(existing, "files", %{}), files_delta))

    File.write!(path, Jason.encode!(manifest, pretty: true) <> "\n")
  end

  defp read_manifest(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, map} <- Jason.decode(raw) do
      map
    else
      _ -> %{}
    end
  end

  defp sha256(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)
end
