defmodule ReqManagedAgents.Stream do
  @moduledoc "Compatibility entry point for `ReqManagedAgents.Providers.ClaudeManagedAgents.Stream`."
  @spec stream(ReqManagedAgents.Client.t(), String.t(), pid(), keyword()) :: :ok
  defdelegate stream(client, session_id, subscriber, opts \\ []),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Stream
end
