defmodule ReqManagedAgents.Host.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: ReqManagedAgents.Host.Registry},
      {DynamicSupervisor, name: ReqManagedAgents.Host.SessionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: ReqManagedAgents.Host.Supervisor
    )
  end
end
