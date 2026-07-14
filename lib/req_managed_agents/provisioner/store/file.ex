defmodule ReqManagedAgents.Provisioner.Store.File do
  @moduledoc """
  Persistent JSON-file store: provision handles and tags survive OS-process
  restarts (CLI tools, mix tasks, cron). One flat JSON object per file;
  writes are atomic (temp file + rename). **Single-writer assumption**: this
  is a workstation/task-runner store, not a concurrent-fleet store. A missing
  or corrupt file is treated as empty (with a logged warning) — the durable
  provider resources are recoverable regardless.

  Values must be JSON-encodable (provision handles are structs that encode to
  a plain three-field JSON object; atom keys round-trip as strings, which is
  fine for handle maps read back via string-keyed access — store consumers in
  this library only ever compare whole values or read string keys).
  """
  @behaviour ReqManagedAgents.Provisioner.Store
  require Logger

  @impl true
  def get(opts, key) do
    case Map.fetch(read(path!(opts)), key) do
      {:ok, value} -> {:ok, value}
      :error -> :miss
    end
  end

  @impl true
  def put(opts, key, value) do
    path = path!(opts)
    write(path, Map.put(read(path), key, normalize(value)))
  end

  @impl true
  def delete(opts, key) do
    path = path!(opts)
    write(path, Map.delete(read(path), key))
  end

  @impl true
  def delete_value(opts, value) do
    path = path!(opts)
    norm = normalize(value)
    write(path, read(path) |> Enum.reject(fn {_k, v} -> v == norm end) |> Map.new())
  end

  defp path!(opts), do: Keyword.fetch!(opts, :path)

  # Values round-trip through JSON; normalize on write so delete_value/2
  # comparisons match what get/2 returns (string keys).
  defp normalize(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp read(path) do
    case Elixir.File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{} = map} ->
            map

          _ ->
            Logger.warning("provision store file corrupt, treating as empty: #{path}")
            %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning(
          "provision store file unreadable (#{inspect(reason)}), treating as empty: #{path}"
        )

        %{}
    end
  end

  defp write(path, map) do
    tmp = path <> ".tmp.#{System.unique_integer([:positive])}"
    Elixir.File.write!(tmp, Jason.encode!(map))
    :ok = Elixir.File.rename(tmp, path)
    :ok
  end
end
