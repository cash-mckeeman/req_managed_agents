defmodule ReqManagedAgents.Artifacts.ClaudeFiles do
  @moduledoc "Compatibility entry point for `ReqManagedAgents.Providers.ClaudeManagedAgents.Artifacts`."
  @behaviour ReqManagedAgents.Artifacts
  defdelegate outputs_dir(), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Artifacts
  defdelegate output_path(name), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Artifacts

  defdelegate store(client, session_id, opts \\ []),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Artifacts

  @impl true
  defdelegate list(store, opts \\ []),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Artifacts

  @impl true
  defdelegate fetch(store, name, opts \\ []),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Artifacts

  @impl true
  defdelegate put(store, name, contents, opts \\ []),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Artifacts

  @impl true
  defdelegate delete(store, name, opts \\ []),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Artifacts
end
