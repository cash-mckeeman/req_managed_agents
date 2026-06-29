defmodule ReqManagedAgents.Providers.ManagedAgents do
  @moduledoc """
  `ReqManagedAgents.Provider` implementation for the Anthropic Managed Agents (SSE) backend.

  Client-side tool calls arrive as `agent.custom_tool_use` events; a
  `session.status_idle` with `stop_reason.type == "requires_action"` lists the
  `event_ids` requiring local execution. Only those ids are surfaced as
  `custom_tool_uses` — provider-executed tools are not in `event_ids` and stay in
  the raw events. `normalize/1` keys off the most recent status event so it is
  correct when called on session-wide accumulated events.
  """
  @behaviour ReqManagedAgents.Provider

  alias ReqManagedAgents.Event

  @impl true
  def decode(buffer), do: ReqManagedAgents.SSE.decode(buffer)

  @impl true
  def normalize(events) do
    uses_by_id =
      for %{"type" => "agent.custom_tool_use", "id" => id} = e <- events, into: %{}, do: {id, e}

    case latest_status(events) do
      %{"type" => "session.status_idle", "stop_reason" => %{"type" => reason} = sr} ->
        custom_tool_uses =
          sr
          |> Map.get("event_ids", [])
          |> Enum.map(&uses_by_id[&1])
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn e -> %{id: e["id"], name: e["name"], input: e["input"]} end)

        outcome(terminal(reason), reason, custom_tool_uses)

      %{"type" => "session.status_terminated"} ->
        outcome(:terminated, "terminated", [])

      %{"type" => "session.error"} ->
        outcome(:terminated, "error", [])

      nil ->
        outcome(:terminated, nil, [])
    end
  end

  @impl true
  def terminal("end_turn"), do: :end_turn
  def terminal("requires_action"), do: :requires_action
  def terminal(_other), do: :terminated

  @impl true
  def resume(_custom_tool_uses, results) do
    Enum.map(results, fn r ->
      Event.custom_tool_result(r.tool_use_id, r.text, is_error: r.is_error)
    end)
  end

  # `text` is best-effort; the assistant-text event shape is captured in a follow-up.
  defp outcome(terminal, reason, custom_tool_uses),
    do: %{terminal: terminal, stop_reason: reason, custom_tool_uses: custom_tool_uses, text: ""}

  defp latest_status(events) do
    events
    |> Enum.reverse()
    |> Enum.find(fn
      %{"type" => "session.status_idle"} -> true
      %{"type" => "session.status_terminated"} -> true
      %{"type" => "session.error"} -> true
      _ -> false
    end)
  end
end
