defmodule ReqManagedAgents.Client.Behaviour do
  @moduledoc """
  Callback contract for the Managed Agents control plane, so consumers can swap in
  a mock client in tests. `ReqManagedAgents.Client` is the live implementation.
  """
  alias ReqManagedAgents.Client

  @type result :: {:ok, map()} | {:error, term()}

  @callback create_agent(Client.t(), map()) :: result()
  @callback get_agent(Client.t(), String.t()) :: result()
  @callback update_agent(Client.t(), String.t(), map()) :: result()
  @callback list_agents(Client.t(), map()) :: result()

  @callback create_environment(Client.t(), map()) :: result()
  @callback get_environment(Client.t(), String.t()) :: result()
  @callback list_environments(Client.t(), map()) :: result()
  @callback archive_agent(Client.t(), String.t()) :: result()
  @callback archive_environment(Client.t(), String.t()) :: result()
  @callback archive_session(Client.t(), String.t()) :: result()

  @callback create_session(Client.t(), map()) :: result()
  @callback get_session(Client.t(), String.t()) :: result()
  @callback list_sessions(Client.t(), map()) :: result()
  @callback delete_session(Client.t(), String.t()) :: result()

  @callback send_events(Client.t(), String.t(), [map()]) :: result()
  @callback send_event(Client.t(), String.t(), map()) :: result()
  @callback list_events(Client.t(), String.t(), map()) :: result()
end
