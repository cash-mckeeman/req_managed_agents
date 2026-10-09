defmodule ReqManagedAgents.Event do
  @moduledoc "Compatibility entry point for `ReqManagedAgents.Providers.ClaudeManagedAgents.Event`."

  @type event :: ReqManagedAgents.Providers.ClaudeManagedAgents.Event.event()
  @type terminal :: ReqManagedAgents.Providers.ClaudeManagedAgents.Event.terminal()

  defdelegate user_message(text), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Event

  defdelegate define_outcome(description, rubric_md, opts \\ []),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Event

  defdelegate custom_tool_result(id, text, opts \\ []),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Event

  defdelegate tool_confirmation(id, decision),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Event

  defdelegate classify(event), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Event
end
