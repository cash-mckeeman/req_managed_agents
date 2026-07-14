defmodule Mix.Tasks.Rma.Capture do
  @shortdoc "Capture a live provider round trip into the private conformance corpus"
  @moduledoc """
  Maintainer task: runs each wired live scenario against a real provider,
  redacts the captured request/response bodies, and writes them into
  `$RMA_CORPUS_DIR/<surface>/{requests,responses}/<name>.json`, stamping
  `$RMA_CORPUS_DIR/<surface>/manifest.json`.

  Requires live AWS credentials (`SigV4.from_env/1`'s env vars) and
  `RMA_CORPUS_DIR` (the private conformance corpus checkout). No-ops with a
  clear instruction when either is missing — it never crashes a maintainer's
  shell:

      RMA_CORPUS_DIR=/path/to/corpus mix rma.capture

  Not shipped in the hex package (`lib/mix` is excluded from `package.files`)
  and not exercised by CI.

  Ships two surfaces: AgentCore `ListHarnesses` (a side-effect-free
  control-plane read, gated on AWS credentials) and Claude Managed Agents
  `create_agent`/`create_environment` (gated on `ANTHROPIC_API_KEY`). The CMA
  scenario provisions a throwaway agent + environment, captures both create
  bodies, then best-effort archives both so a maintainer's account isn't left
  with orphaned resources. Add more `{name, fun}` tuples to `scenarios/1` for
  more AgentCore reads as they're needed.

  ## Relationship to `test/support/conformance/capture.ex`

  Redaction is shared: both this task and the test-support harness call the
  ReqManagedAgents.Conformance.Redaction module, which lives in `lib/` precisely
  so a `:dev` mix task can use it (`test/support` isn't compiled in `:dev`).
  Every written body is redacted and then leak-scanned (scan_string/1) before it
  touches disk.

  The WRITER itself is still separate — the ReqManagedAgents.Conformance.Capture
  write_pair/5 (test-support) is the unit-tested reference in
  `test/conformance/capture_test.exs`; this task's write_pair!/6 mirrors it
  (plus the leak-scan guard). Keep the two writers in sync by hand if either
  changes.
  """
  use Mix.Task

  alias ReqManagedAgents.AgentCore.{Client, SigV4}
  alias ReqManagedAgents.Client, as: CMAClient
  alias ReqManagedAgents.Conformance.Redaction

  @impl Mix.Task
  def run(_argv) do
    case fetch_corpus_dir() do
      {:ok, corpus_dir} ->
        run_agentcore(corpus_dir)
        run_cma(corpus_dir)

      {:error, message} ->
        Mix.shell().info(message)
    end
  end

  defp run_agentcore(corpus_dir) do
    case fetch_credentials() do
      {:ok, credentials} ->
        client = Client.new(credentials: credentials)
        Enum.each(scenarios(client), &capture_scenario!(corpus_dir, &1))

      {:error, message} ->
        Mix.shell().info(message)
    end
  end

  defp run_cma(corpus_dir) do
    case fetch_cma_api_key() do
      {:ok, api_key} ->
        capture_cma!(corpus_dir, CMAClient.new(api_key: api_key))

      {:error, message} ->
        Mix.shell().info(message)
    end
  end

  # Extension point: append {name, fn -> {:ok, req_json, resp_json} | {:error, term()} end}
  # tuples as more live scenarios are wired.
  defp scenarios(client) do
    [
      {"list_harnesses",
       fn ->
         case Client.list_harnesses(client) do
           {:ok, resp} -> {:ok, %{}, resp}
           {:error, reason} -> {:error, reason}
         end
       end}
    ]
  end

  defp capture_scenario!(corpus_dir, {name, fun}) do
    case fun.() do
      {:ok, req_json, resp_json} ->
        write_pair!(corpus_dir, :agentcore, name, req_json, resp_json, DateTime.utc_now())
        Mix.shell().info("captured agentcore/#{name}")

      {:error, reason} ->
        Mix.shell().info("skipped #{name}: #{inspect(reason)}")
    end
  end

  defp fetch_corpus_dir do
    case System.get_env("RMA_CORPUS_DIR") do
      dir when is_binary(dir) and dir != "" ->
        {:ok, dir}

      _ ->
        {:error,
         "RMA_CORPUS_DIR is not set — export it to the private conformance corpus " <>
           "checkout and re-run: RMA_CORPUS_DIR=/path/to/corpus mix rma.capture"}
    end
  end

  defp fetch_credentials do
    {:ok, SigV4.from_env()}
  rescue
    RuntimeError ->
      {:error,
       "live AWS credentials not found — export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY " <>
         "(+ AWS_SESSION_TOKEN) and re-run."}
  end

  defp fetch_cma_api_key do
    case System.get_env("ANTHROPIC_API_KEY") do
      key when is_binary(key) and key != "" ->
        {:ok, key}

      _ ->
        {:error,
         "ANTHROPIC_API_KEY is not set — export it and re-run to capture the CMA scenario."}
    end
  end

  # Provisions a throwaway agent + environment via the real CMA request bodies
  # (mirrors ReqManagedAgents.Providers.ClaudeManagedAgents.provision/2's body
  # shapes — bare model id, verbatim environment config), captures both create
  # bodies, then best-effort archives both so nothing real is left orphaned.
  defp capture_cma!(corpus_dir, client) do
    name = "conformance_agent_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    agent_body = %{
      name: name,
      model: "claude-sonnet-4-6",
      system: "You are a helpful assistant.",
      tools: []
    }

    env_body = %{
      name: "#{name}_env",
      config: %{type: "cloud", networking: %{type: "unrestricted"}}
    }

    case CMAClient.create_agent(client, agent_body) do
      {:ok, %{"id" => agent_id} = agent_resp} ->
        # The agent now exists in the maintainer's account. Guarantee it gets
        # archived no matter what follows (env-create failure OR a write raise) —
        # the `after` runs on every exit path, including exceptions.
        try do
          capture_cma_env!(corpus_dir, client, agent_body, agent_resp, env_body)
        after
          _ = CMAClient.archive_agent(client, agent_id)
        end

      {:error, reason} ->
        Mix.shell().info("skipped cma: #{inspect(reason)}")

      other ->
        Mix.shell().info("skipped cma: unexpected response #{inspect(other)}")
    end
  end

  defp capture_cma_env!(corpus_dir, client, agent_body, agent_resp, env_body) do
    case CMAClient.create_environment(client, env_body) do
      {:ok, %{"id" => env_id} = env_resp} ->
        # Same guarantee for the environment: archive it even if a write raises.
        try do
          now = DateTime.utc_now()
          write_pair!(corpus_dir, :cma, "create_agent", agent_body, agent_resp, now)
          write_pair!(corpus_dir, :cma, "create_environment", env_body, env_resp, now)
          Mix.shell().info("captured cma/create_agent, cma/create_environment")
        after
          _ = CMAClient.archive_environment(client, env_id)
        end

      {:error, reason} ->
        Mix.shell().info("skipped cma: environment create failed: #{inspect(reason)}")

      other ->
        Mix.shell().info("skipped cma: unexpected environment response #{inspect(other)}")
    end
  end

  # ---- write (redaction is shared via ReqManagedAgents.Conformance.Redaction) ----

  defp write_pair!(corpus_dir, surface, name, req_json, resp_json, captured_at) do
    dir = Path.join(corpus_dir, to_string(surface))
    File.mkdir_p!(dir)

    req_rel = Path.join("requests", "#{name}.json")
    resp_rel = Path.join("responses", "#{name}.json")

    req_sha = write_json!(dir, req_rel, Redaction.redact(req_json))
    resp_sha = write_json!(dir, resp_rel, Redaction.redact(resp_json))

    update_manifest!(dir, captured_at, %{req_rel => req_sha, resp_rel => resp_sha})
  end

  defp write_json!(dir, relpath, data) do
    path = Path.join(dir, relpath)
    File.mkdir_p!(Path.dirname(path))
    bytes = Jason.encode!(data, pretty: true) <> "\n"

    # Last-line guard: never let a secret-shaped value the key-based redactor
    # missed (a new field, a token in a string value) land in the corpus.
    case Redaction.scan_string(bytes) do
      :ok ->
        File.write!(path, bytes)
        sha256(bytes)

      {:leak, _hits} ->
        Mix.raise(
          "refusing to write #{relpath}: redacted body still matches a secret pattern. " <>
            "Extend ReqManagedAgents.Conformance.Redaction before capturing this scenario."
        )
    end
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
