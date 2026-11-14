defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Federation.Cache do
  @moduledoc false
  # Owns the ETS table of exchanged access tokens. Readers and writers use the
  # table directly; this process exists so the table outlives any caller.
  use GenServer

  alias ReqManagedAgents.Providers.ClaudeManagedAgents.BearerCredential

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The cached credential and the time before which refresh is not retried."
  @spec fetch(term()) :: {BearerCredential.t(), integer()} | nil
  def fetch(key) do
    case :ets.lookup(@table, key) do
      [{^key, credential, retry_at}] -> {credential, retry_at}
      [] -> nil
    end
  end

  @spec put(term(), BearerCredential.t(), integer()) :: :ok
  def put(key, %BearerCredential{} = credential, retry_at) do
    :ets.insert(@table, {key, credential, retry_at})
    :ok
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end
end
