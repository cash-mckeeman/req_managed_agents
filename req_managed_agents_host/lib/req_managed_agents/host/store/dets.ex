defmodule ReqManagedAgents.Host.Store.DETS do
  @moduledoc """
  File-backed `Store` implementation using OTP's `:dets`. The table is
  reopened from the same path on every `start_link/1`, so locator rows
  survive a BEAM restart. A corrupt or unreadable file is logged and
  replaced with a fresh, empty table (mirrors RMA's `Provisioner.Store.File`
  corrupt-file handling) — a lost locator row just means the next lookup
  falls back to provisioning, not a crash.
  """
  use GenServer
  require Logger

  @behaviour ReqManagedAgents.Host.Store

  @impl true
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def ref(opts), do: Keyword.fetch!(opts, :name)

  @impl true
  def put(table, key, value) do
    :dets.insert(table, {key, value})
    :dets.sync(table)
    :ok
  end

  @impl true
  def get(table, key) do
    case :dets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  end

  @impl true
  def delete(table, key) do
    :dets.delete(table, key)
    :ok
  end

  @impl true
  def all(table), do: :dets.match_object(table, :_)

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    path = Keyword.fetch!(opts, :file)

    {:ok, open(name, path)}
  end

  @impl true
  def terminate(_reason, table) do
    :dets.close(table)
    :ok
  end

  defp open(name, path) do
    charlist_path = String.to_charlist(path)

    case :dets.open_file(name, file: charlist_path, type: :set) do
      {:ok, table} ->
        table

      {:error, reason} ->
        Logger.warning(
          "DETS store file corrupt/unreadable (#{inspect(reason)}), replacing: #{path}"
        )

        File.rm(path)

        case :dets.open_file(name, file: charlist_path, type: :set) do
          {:ok, table} ->
            table

          {:error, reopen_reason} ->
            raise "DETS store unrecoverable at #{path}: #{inspect(reopen_reason)}"
        end
    end
  end
end
