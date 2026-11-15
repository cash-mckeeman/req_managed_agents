defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Federation.Cache do
  @moduledoc false
  # Owns the ETS table of exchange results. Readers and writers use the table
  # directly; this process exists so the table outlives any caller.
  use GenServer

  alias ReqManagedAgents.Providers.ClaudeManagedAgents.BearerCredential

  @table __MODULE__

  defmodule Entry do
    @moduledoc false
    # What the last exchanges for one credential produced: the access token, if
    # any with the time it was obtained, and the failure of the latest attempt with the time before which
    # no new attempt is made. `failure` is a reason category, never a body.
    defstruct credential: nil, issued_at: nil, retry_at: 0, failure: nil

    @type t :: %__MODULE__{
            credential: BearerCredential.t() | nil,
            issued_at: integer() | nil,
            retry_at: integer(),
            failure: term()
          }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec fetch(term()) :: Entry.t() | nil
  def fetch(key) do
    case :ets.lookup(@table, key) do
      [{^key, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Stores an entry and drops every entry that holds no live token and no pause at `now`."
  @spec put(term(), Entry.t(), integer()) :: :ok
  def put(key, %Entry{} = entry, now) do
    sweep(:ets.tab2list(@table), now)
    :ets.insert(@table, {key, entry})
    :ok
  end

  @doc false
  # Deletes the spent objects of `snapshot`. Each is removed as the exact object
  # that was read, so an entry another process wrote for the same key since the
  # snapshot survives.
  @spec sweep([{term(), Entry.t()}], integer()) :: :ok
  def sweep(snapshot, now) do
    for {_, old} = object <- snapshot, spent?(old, now), do: :ets.delete_object(@table, object)
    :ok
  end

  defp spent?(%Entry{credential: credential, retry_at: retry_at}, now) do
    retry_at <= now and (credential == nil or credential.expires_at <= now)
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end
end
