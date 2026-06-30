defmodule ReqManagedAgents.Providers.ClaudeManagedAgents do
  @moduledoc """
  `ReqManagedAgents.Provider` implementation for the Anthropic Managed Agents (SSE) backend.

  Client-side tool calls arrive as `agent.custom_tool_use` events; a
  `session.status_idle` with `stop_reason.type == "requires_action"` lists the
  `event_ids` requiring local execution. Only those ids are surfaced as
  `custom_tool_uses`. Provider-executed `agent.tool_use` events never enter
  `custom_tool_uses` — they are surfaced observe-only as `server_tool_uses`.
  `normalize/1` keys off the most recent status event so it is correct when called on
  session-wide accumulated events; it also extracts assistant `text` from `agent.message`.

  > Note: `events`, `text`, and `server_tool_uses` reflect exactly the events passed in.
  > A caller supplying a partial list gets a partial view — the `Session` driver passes a
  > stash-derived list holding only `agent.custom_tool_use` events (it needs `normalize/1`
  > for control flow only), so off Session those fields cover just that list. The full raw
  > stream is still available to consumers another way: `RunToCompletion`/`invoke_to_completion`
  > return the accumulated `events`, and `Session` delivers every raw event to the Handler's
  > `handle_event/2`. Surfacing the full normalized view off Session would require it to
  > accumulate the turn's events (future work).
  """
  @behaviour ReqManagedAgents.Provider

  alias ReqManagedAgents.Event

  @impl true
  def decode(buffer), do: ReqManagedAgents.SSE.decode(buffer)

  @impl true
  def normalize(events) do
    uses_by_id =
      for %{"type" => "agent.custom_tool_use", "id" => id} = e <- events, into: %{}, do: {id, e}

    extra = %{server_tool_uses: server_tool_uses(events), text: assistant_text(events), events: events}

    case latest_status(events) do
      %{"type" => "session.status_idle", "stop_reason" => %{"type" => reason} = sr} ->
        custom_tool_uses =
          sr
          |> Map.get("event_ids", [])
          |> Enum.map(&uses_by_id[&1])
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn e -> %{id: e["id"], name: e["name"], input: e["input"]} end)

        outcome(terminal(reason), reason, custom_tool_uses, extra)

      %{"type" => "session.status_terminated"} ->
        outcome(:terminated, "terminated", [], extra)

      %{"type" => "session.error"} ->
        outcome(:terminated, "error", [], extra)

      # A status_idle whose stop_reason carries no recognizable type — e.g. a null
      # stop_reason, which is jido's creation-time / end_turn idle. Its terminal verdict
      # is context-dependent ("agent seen?") and is `ReqManagedAgents.Profile`'s job, not
      # this provider's; the anthropic shape this provider targets always carries a typed
      # stop_reason. Defensive: never crash — conservatively treat an unrecognized idle as
      # terminal (the spec's `unknown_idle -> :terminated` row), preventing a hang.
      %{"type" => "session.status_idle"} ->
        outcome(:terminated, nil, [], extra)

      # No status event present, or any other unrecognized shape.
      _ ->
        outcome(:terminated, nil, [], extra)
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

  defp outcome(terminal, reason, custom_tool_uses, extra),
    do: Map.merge(%{terminal: terminal, stop_reason: reason, custom_tool_uses: custom_tool_uses}, extra)

  # Server-side (provider-executed) tool calls — observe-only, surfaced for telemetry/UI.
  # Shape verified against the biai-platform consumer: `%{"type" => "agent.tool_use",
  # "id" => …, "name" => …, "input" => …}` — distinct from the client-side
  # `agent.custom_tool_use`. These NEVER enter `custom_tool_uses`: the managed loop runs
  # them itself. The event `id` is kept (it is the key biai-platform dedups/correlates on,
  # e.g. to a future `agent.tool_result`). Requires only the agent.tool_use type +
  # `name`; `input` defaults to `%{}` so a no-arg server tool is not silently dropped.
  defp server_tool_uses(events) do
    for %{"type" => "agent.tool_use", "name" => name} = e <- events,
        do: %{id: e["id"], name: name, input: e["input"] || %{}}
  end

  # Assistant text for the turn: the `text` blocks of every `agent.message` event, joined
  # with "\n" to match the biai-platform consumer's `text_of/1`. Shape verified against
  # Anthropic's Managed Agents docs and that consumer —
  # `%{"type" => "agent.message", "content" => [%{"type" => "text", "text" => …}, …]}`.
  # Non-text blocks (thinking / tool_use) are filtered out before joining.
  defp assistant_text(events) do
    events
    |> Enum.flat_map(fn
      %{"type" => "agent.message", "content" => blocks} when is_list(blocks) -> blocks
      _ -> []
    end)
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("\n")
  end

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
