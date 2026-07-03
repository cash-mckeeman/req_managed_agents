defmodule ReqManagedAgents.Artifacts.AgentCoreSessionStorage do
  @moduledoc """
  `ReqManagedAgents.Artifacts` store over an AgentCore harness `sessionStorage`
  mount (the no-VPC filesystem type), backed by `InvokeAgentRuntimeCommand`.

  Verbs run python3 one-liners in the session microVM (python3 is guaranteed in
  the base image); file bytes transit the command stream as Base64, so this
  store is for report-scale artifacts, not GB-scale data. Names are restricted
  to `[A-Za-z0-9._-]` (no separators, no traversal). A verb that exits non-zero
  unexpectedly returns `{:error, {:command_failed, %CommandResult{}}}` — stderr
  is never swallowed.
  """
  @behaviour ReqManagedAgents.Artifacts

  alias ReqManagedAgents.AgentCore.Client, as: AgentCoreClient
  alias ReqManagedAgents.AgentCore.CommandResult
  alias ReqManagedAgents.Artifact

  @name_re ~r/^[A-Za-z0-9._-]+$/
  @not_found_exit 3
  # Wire caps "command" at 65_536 chars; leave headroom for the wrapper code.
  @b64_chunk 48_000

  @doc """
  Build a store term. `base_path` is the harness's `sessionStorage` mountPath
  (e.g. `"/mnt/data"`). `command_fun` is injectable for tests; defaults to
  `ReqManagedAgents.AgentCore.Client.invoke_agent_runtime_command/2` on `client`.
  """
  def store(client, agent_runtime_arn, runtime_session_id, base_path, opts \\ []) do
    %{
      arn: agent_runtime_arn,
      sid: runtime_session_id,
      base: String.trim_trailing(base_path, "/"),
      command_fun:
        opts[:command_fun] ||
          fn inv ->
            AgentCoreClient.invoke_agent_runtime_command(client, inv)
          end
    }
  end

  @impl true
  def list(store, _opts \\ []) do
    code = """
    import json,os,sys
    b=sys.argv[1]
    print(json.dumps([{"name":e.name,"size":e.stat().st_size} for e in os.scandir(b) if e.is_file()]))
    """

    with {:ok, %CommandResult{exit_code: 0, stdout: out}} <- run(store, code, [store.base]),
         {:ok, entries} <- Jason.decode(out) do
      {:ok, Enum.map(entries, &entry_to_artifact(&1, store.base))}
    else
      {:ok, %CommandResult{} = r} -> {:error, {:command_failed, r}}
      {:error, %Jason.DecodeError{} = e} -> {:error, {:unexpected_list_output, e}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def fetch(store, name, _opts \\ []) do
    with :ok <- validate(name) do
      code = """
      import base64,os,sys
      p=sys.argv[1]
      if not os.path.isfile(p): sys.exit(#{@not_found_exit})
      sys.stdout.write(base64.b64encode(open(p,"rb").read()).decode())
      """

      case run(store, code, [path(store, name)]) do
        {:ok, %CommandResult{exit_code: 0, stdout: b64}} ->
          decode_b64(b64)

        {:ok, %CommandResult{exit_code: @not_found_exit}} ->
          {:error, :not_found}

        {:ok, %CommandResult{} = r} ->
          {:error, {:command_failed, r}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def put(store, name, contents, _opts \\ []) do
    with :ok <- validate(name) do
      do_put(store, name, contents)
    end
  end

  @impl true
  def delete(store, name, _opts \\ []) do
    with :ok <- validate(name) do
      code = """
      import os,sys
      p=sys.argv[1]
      if not os.path.isfile(p): sys.exit(#{@not_found_exit})
      os.remove(p)
      """

      case run(store, code, [path(store, name)]) do
        {:ok, %CommandResult{exit_code: 0}} -> :ok
        {:ok, %CommandResult{exit_code: @not_found_exit}} -> {:error, :not_found}
        {:ok, %CommandResult{} = r} -> {:error, {:command_failed, r}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ── plumbing ────────────────────────────────────────────────────────────────

  defp do_put(store, name, contents) do
    tmp = path(store, name) <> ".rma_b64_part"
    chunks = contents |> Base.encode64() |> chunk_every(@b64_chunk)

    append_code = """
    import sys
    open(sys.argv[1],"a").write(sys.argv[2])
    """

    finish_code = """
    import base64,os,sys
    t,p=sys.argv[1],sys.argv[2]
    open(p,"wb").write(base64.b64decode(open(t).read()))
    os.remove(t)
    """

    with :ok <- run_all(store, append_code, tmp, chunks),
         {:ok, %CommandResult{exit_code: 0}} <- run(store, finish_code, [tmp, path(store, name)]) do
      :ok
    else
      {:ok, %CommandResult{} = r} -> {:error, {:command_failed, r}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(store, python_code, argv) do
    args = Enum.map_join(argv, " ", &("'" <> &1 <> "'"))

    store.command_fun.(%{
      agent_runtime_arn: store.arn,
      runtime_session_id: store.sid,
      command: "python3 -c '#{escape_single_quotes(python_code)}' #{args}"
    })
  end

  defp run_all(_store, _code, _tmp, []), do: :ok

  defp run_all(store, code, tmp, [chunk | rest]) do
    case run(store, code, [tmp, chunk]) do
      {:ok, %CommandResult{exit_code: 0}} -> run_all(store, code, tmp, rest)
      {:ok, %CommandResult{} = r} -> {:error, {:command_failed, r}}
      {:error, reason} -> {:error, reason}
    end
  end

  # POSIX single-quote escaping: close, escaped quote, reopen. argv values are
  # library-controlled (validated names, base_path, base64) — this guards the
  # python SOURCE, which contains no single quotes by construction, defensively.
  defp escape_single_quotes(s), do: String.replace(s, "'", "'\\''")

  defp chunk_every(string, size) do
    string |> :binary.bin_to_list() |> Enum.chunk_every(size) |> Enum.map(&:binary.list_to_bin/1)
  end

  defp path(store, name), do: store.base <> "/" <> name

  defp validate(name) do
    if Regex.match?(@name_re, name), do: :ok, else: {:error, {:invalid_name, name}}
  end

  defp decode_b64(b64) do
    case Base.decode64(b64, ignore: :whitespace) do
      {:ok, data} -> {:ok, data}
      :error -> {:error, :bad_base64}
    end
  end

  defp entry_to_artifact(%{"name" => n, "size" => s}, base) do
    %Artifact{name: n, size: s, ref: base <> "/" <> n, raw: nil}
  end
end
