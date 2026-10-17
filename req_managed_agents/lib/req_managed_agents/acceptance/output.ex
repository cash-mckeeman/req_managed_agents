defmodule ReqManagedAgents.Acceptance.Output do
  @moduledoc false
  import Bitwise, only: [band: 2]
  alias ReqManagedAgents.Acceptance.Report

  @doc false
  @spec validate(String.t() | nil) :: :ok | {:error, atom()}
  def validate(nil), do: :ok

  def validate(path) when is_binary(path) do
    case {File.lstat(path), File.lstat(Path.dirname(path))} do
      {{:error, :enoent}, {:ok, %File.Stat{type: :directory, mode: mode}}} ->
        if band(mode, 0o077) == 0 and safe_ancestors?(Path.dirname(path)) and
             owned?(Path.dirname(path)), do: :ok, else: {:error, :output_ownership}

      _ ->
        {:error, :output_collision}
    end
  end

  def validate(_), do: {:error, :output_required}

  @doc false
  @spec create(String.t()) :: :ok | {:error, atom()}
  def create(path) when is_binary(path) do
    with :ok <- validate(path), :ok <- File.mkdir(path), do: File.chmod(path, 0o700)
  end

  def create(_), do: {:error, :output_required}

  @doc false
  @spec report(Report.t(), String.t()) :: :ok | {:error, atom()}
  def report(report, root) do
    target = Path.join(root, "report.json")

    with {:ok, file} <- File.open(target, [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(target, 0o600),
             :ok <- IO.binwrite(file, Jason.encode!(Report.to_wire(report))),
             do: :file.sync(file)
      after
        File.close(file)
      end
    end
  end

  defp safe_ancestors?(path) do
    Path.expand(path)
    |> Path.split()
    |> Enum.reduce_while("", fn part, prefix ->
      next = if prefix == "", do: part, else: Path.join(prefix, part)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, next}
        _ -> {:halt, false}
      end
    end) != false and not Enum.member?(Path.split(path), "..")
  end

  defp owned?(path) do
    case {System.cmd("id", ["-u"]), File.lstat(path)} do
      {{uid, 0}, {:ok, %File.Stat{uid: owner}}} -> String.trim(uid) == Integer.to_string(owner)
      _ -> false
    end
  end
end
