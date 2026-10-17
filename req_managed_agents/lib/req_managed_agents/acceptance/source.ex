defmodule ReqManagedAgents.Acceptance.Source do
  @moduledoc """
  Attests checkout identity and the active Mix build before credential resolution.

  Configured build inputs must belong to the requested immutable revision.
  Compiled input fingerprints and loaded BEAM identities detect stale local builds.
  This assumes trusted local code and build files; it does not authenticate them.
  """
  import Bitwise, only: [band: 2]
  @root Path.expand("../../../..", __DIR__)
  @package Path.join(@root, "req_managed_agents")
  @source_dirs Enum.map(
                 Mix.Project.config()[:elixirc_paths] || ["lib"],
                 &Path.expand(&1, @package)
               )
  @config_dirs [Path.join(@root, "config"), Path.join(@package, "config")]
  @config_paths Enum.flat_map(
                  @config_dirs,
                  &Path.wildcard(Path.join(&1, "**/*.{ex,exs}"), match_dot: true)
                )
  @metadata_paths for base <- [@root, @package, Path.join(@root, "req_managed_agents_host")],
                      name <- ["mix.exs", "mix.lock"],
                      do: Path.join(base, name)
  @input_paths (Enum.flat_map(
                  @source_dirs,
                  &Path.wildcard(Path.join(&1, "**/*.ex"), match_dot: true)
                ) ++
                  @config_paths ++
                  Enum.filter(@metadata_paths, &File.regular?/1))
               |> Enum.uniq()
               |> Enum.sort()
  @compiled_inputs Map.new(@input_paths, &{&1, :crypto.hash(:sha256, File.read!(&1))})
  for path <- @input_paths, do: @external_resource(path)

  @enforce_keys [:revision, :tree, :root]
  defstruct @enforce_keys
  @type t :: %__MODULE__{revision: String.t(), tree: String.t(), root: String.t()}

  @doc "Verify this task's compiled source checkout, never a caller-selected checkout."
  @spec attest(String.t()) :: {:ok, t()} | {:error, :source_mismatch}
  def attest(revision) do
    with {:ok, source} <- verify(@root, revision),
         true <- tracked_inputs?(source.revision),
         true <- current_build?() do
      {:ok, source}
    else
      _ -> {:error, :source_mismatch}
    end
  rescue
    _ -> {:error, :source_mismatch}
  catch
    :exit, _ -> {:error, :source_mismatch}
  end

  @doc false
  def __mix_recompile__?, do: input_paths() != @input_paths

  defp input_paths do
    (Enum.flat_map(@source_dirs, &Path.wildcard(Path.join(&1, "**/*.ex"), match_dot: true)) ++
       Enum.flat_map(
         @config_dirs,
         &Path.wildcard(Path.join(&1, "**/*.{ex,exs}"), match_dot: true)
       ) ++
       Enum.filter(@metadata_paths, &File.regular?/1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp current_build? do
    Path.expand(Mix.Project.project_file()) == Path.join(@package, "mix.exs") and
      Enum.map(Mix.Project.config()[:elixirc_paths] || ["lib"], &Path.expand(&1, @package)) ==
        @source_dirs and
      input_paths() == @input_paths and Enum.all?(@compiled_inputs, &current_input?/1) and
      current_modules?()
  end

  defp tracked_inputs?(revision) do
    case command("git", ["-C", @root, "ls-tree", "-rz", "--full-tree", "--name-only", revision]) do
      {:ok, listing} ->
        paths = MapSet.new(String.split(listing, <<0>>, trim: true))
        Enum.all?(@input_paths, &MapSet.member?(paths, Path.relative_to(&1, @root)))

      _ ->
        false
    end
  end

  defp current_input?({path, digest}) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes) == digest
      _ -> false
    end
  end

  defp current_modules? do
    compile_path = Path.expand(Mix.Project.compile_path())
    app_file = Path.join(compile_path, "req_managed_agents.app")

    with {:ok, [{:application, :req_managed_agents, properties}]} <-
           :file.consult(String.to_charlist(app_file)),
         modules when is_list(modules) <- Keyword.get(properties, :modules),
         true <- __MODULE__ in modules do
      Enum.all?(modules, &current_module?(&1, compile_path))
    else
      _ -> false
    end
  end

  defp current_module?(module, compile_path) do
    expected = Path.join(compile_path, Atom.to_string(module) <> ".beam")

    with {:module, ^module} <- Code.ensure_loaded(module),
         path when is_list(path) <- :code.which(module),
         true <- Path.expand(List.to_string(path)) == expected,
         {:ok, {^module, digest}} <- :beam_lib.md5(String.to_charlist(expected)) do
      module.module_info(:md5) == digest
    else
      _ -> false
    end
  end

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

  defp command_root("jj", args) do
    index = Enum.find_index(args, &(&1 == "-R"))
    if index, do: Enum.at(args, index + 1), else: @root
  end

  defp command_root(_, _), do: @root

  defp command(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true, cd: command_root(command, args)) do
      {output, 0} -> {:ok, output}
      _ -> :error
    end
  rescue
    ErlangError -> :error
  end
end
