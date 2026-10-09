defmodule ReqManagedAgents.Consolidate do
  @moduledoc "Compatibility entry point for `ReqManagedAgents.Providers.ClaudeManagedAgents.Consolidate`."

  defdelegate dedupe(events, seen), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Consolidate

  defdelegate unanswered_tool_uses(history),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Consolidate

  defdelegate pending_requires_action(history),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Consolidate
end
