defmodule ReqManagedAgents.Profile do
  @moduledoc "Compatibility entry point for `ReqManagedAgents.Providers.ClaudeManagedAgents.Profile`."

  @type t :: ReqManagedAgents.Providers.ClaudeManagedAgents.Profile.t()

  defdelegate tool_use(profile, event), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Profile

  defdelegate events_stream_path(profile, id),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Profile

  defdelegate terminal?(profile, event, seen?),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Profile
end
