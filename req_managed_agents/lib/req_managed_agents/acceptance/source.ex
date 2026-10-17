defmodule ReqManagedAgents.Acceptance.Source do
  @moduledoc "Attests immutable source against the actual tracked checkout before credentials are read."
  import Bitwise, only: [band: 2]
  @root Path.expand("../../../..", __DIR__)
  @enforce_keys [:revision, :tree, :root]
  defstruct @enforce_keys
  @type t :: %__MODULE__{revision: String.t(), tree: String.t(), root: String.t()}

  @doc "Verify this task's compiled source checkout, never a caller-selected checkout."
  @spec attest(String.t()) :: {:ok, t()} | {:error, :source_mismatch}
  def attest(revision), do: verify(@root, revision)

  @doc false
  @spec verify(String.t(), String.t()) :: {:ok, t()} | {:error, :source_mismatch}
  def verify(root, revision) do
    with true <- is_binary(revision) and Regex.match?(~r/\A[0-9a-f]{40}\z/, revision),
         {:ok, tree} <- command("git", ["-C", root, "rev-parse", "#{revision}^{tree}"]),
         {:ok, listing} <- command("git", ["-C", root, "ls-tree", "-rz", "--full-tree", revision]),
         entries = String.split(listing, <<0>>, trim: true),
         true <- entries != [] and Enum.all?(entries, &matches?(root, &1)),
         true <- compiled_inventory?(root, entries),
         :ok <- tracked_identity(root, revision, entries) do
      {:ok, %__MODULE__{revision: revision, tree: String.trim(tree), root: root}}
    else
      _ -> {:error, :source_mismatch}
    end
  end

  defp tracked_identity(root, revision, entries) do
    if File.dir?(Path.join(root, ".jj")) do
      with {:ok, actual_root} <- command("jj", ["--ignore-working-copy", "-R", root, "root"]),
           true <- String.trim(actual_root) == root,
           {:ok, actual} <-
             command("jj", [
               "--ignore-working-copy",
               "-R",
               root,
               "log",
               "-r",
               "@",
               "--no-graph",
               "-T",
               "if(empty, parents.map(|c| c.commit_id()).join(\" \"), commit_id)"
             ]),
           true <- String.trim(actual) == revision,
           {:ok, current} <- command("jj", ["--ignore-working-copy", "-R", root, "file", "list"]),
           paths = Enum.map(entries, &(String.split(&1, "\t", parts: 2) |> List.last())),
           true <- Enum.sort(String.split(current, "\n", trim: true)) == Enum.sort(paths) do
        :ok
      else
        _ -> :error
      end
    else
      with {:ok, head} <- command("git", ["-C", root, "rev-parse", "HEAD"]),
           true <- String.trim(head) == revision,
           {:ok, ""} <-
             command("git", ["-C", root, "status", "--porcelain", "--untracked-files=normal"]) do
        :ok
      else
        _ -> :error
      end
    end
  end

  defp compiled_inventory?(root, entries) do
    dirs = ["lib", "req_managed_agents/lib", "req_managed_agents_host/lib"]

    physical =
      Enum.flat_map(dirs, fn dir ->
        Path.wildcard(Path.join([root, dir, "**/*.ex"]), match_dot: true)
      end)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()

    tracked =
      Enum.map(entries, &(String.split(&1, "\t", parts: 2) |> List.last()))
      |> Enum.filter(fn path ->
        String.ends_with?(path, ".ex") and Enum.any?(dirs, &String.starts_with?(path, &1 <> "/"))
      end)
      |> Enum.sort()

    physical == tracked
  end

  defp matches?(root, entry) do
    case String.split(entry, [" ", "\t"], parts: 4) do
      [mode, "blob", sha, path] when mode in ["100644", "100755"] ->
        full = Path.join(root, path)

        with {:ok, %{type: :regular, mode: actual}} <- File.lstat(full),
             true <- band(actual, 0o111) != 0 == (mode == "100755"),
             {:ok, bytes} <- File.read(full) do
          Base.encode16(:crypto.hash(:sha, ["blob #{byte_size(bytes)}", <<0>>, bytes]),
            case: :lower
          ) == sha
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp command(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      _ -> :error
    end
  rescue
    ErlangError -> :error
  end
end
