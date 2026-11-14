defmodule ReqManagedAgents.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: ReqManagedAgents.StreamFinch},
      ReqManagedAgents.Providers.ClaudeManagedAgents.Federation.Cache
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ReqManagedAgents.Supervisor)
  end
end
