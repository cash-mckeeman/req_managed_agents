defmodule ReqManagedAgents.Host.SessionSupervisor do
  @moduledoc """
  `DynamicSupervisor` holding one live `SessionServer` per external id. Crash-isolated:
  killing one server never affects a sibling. `start_or_get/2` is the sole entry point —
  it starts a fresh server or hands back the pid of one already registered under the same
  external id, resolving the race where two callers both call it concurrently for the same id.
  """
  alias ReqManagedAgents.Host.{Config, SessionServer}

  @doc "Start (or fetch, if a race lost) the `SessionServer` for `external_id`."
  @spec start_or_get(String.t(), Config.t()) :: {:ok, pid()} | {:error, term()}
  def start_or_get(external_id, %Config{} = config) do
    case DynamicSupervisor.start_child(__MODULE__, {SessionServer, {external_id, config}}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end
end
