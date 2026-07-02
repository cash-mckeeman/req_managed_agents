defmodule ReqManagedAgents.SessionSupervisor do
  @moduledoc """
  Optional `DynamicSupervisor` for running one `ReqManagedAgents.Session` per
  child. Add it to your supervision tree, then `start_child/1` with the same opts
  you'd pass to `ReqManagedAgents.Session.start_link/2`.
  """
  use DynamicSupervisor

  def start_link(init_arg \\ []),
    do: DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl true
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Start a supervised live session (Claude Managed Agents)."
  def start_child(opts),
    do:
      DynamicSupervisor.start_child(
        __MODULE__,
        {ReqManagedAgents.Session, {ReqManagedAgents.Providers.ClaudeManagedAgents, opts}}
      )
end
