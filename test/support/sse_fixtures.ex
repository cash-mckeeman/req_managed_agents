defmodule ReqManagedAgents.SSEFixtures do
  @moduledoc false

  @doc "Render a list of event maps as an SSE wire string (one frame each)."
  def wire(events) when is_list(events) do
    Enum.map_join(events, "", fn ev ->
      "event: #{ev["type"]}\ndata: #{Jason.encode!(ev)}\n\n"
    end)
  end

  def custom_tool_use(id, name, input),
    do: %{"type" => "agent.custom_tool_use", "id" => id, "name" => name, "input" => input}

  def requires_action(event_ids),
    do: %{
      "type" => "session.status_idle",
      "stop_reason" => %{"type" => "requires_action", "event_ids" => event_ids}
    }

  def end_turn,
    do: %{"type" => "session.status_idle", "stop_reason" => %{"type" => "end_turn"}}

  @doc """
  An `agent.message` (assistant text) event. Shape verified against Anthropic's Managed
  Agents docs and the biai-platform consumer:
  `%{"type" => "agent.message", "content" => [%{"type" => "text", "text" => …}]}`.
  """
  def agent_message(text, opts \\ []) do
    base = %{"type" => "agent.message", "content" => [%{"type" => "text", "text" => text}]}
    case opts[:id] do
      nil -> base
      id -> Map.put(base, "id", id)
    end
  end
end
