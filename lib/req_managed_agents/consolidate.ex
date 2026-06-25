defmodule ReqManagedAgents.Consolidate do
  @moduledoc """
  Pure helpers for reconnect-with-consolidation.

  The event stream has **no replay**: on (re)connect a consumer lists past events
  and must (a) drop ones it already processed and (b) re-drive any tool call left
  unanswered across the disconnect, or the session deadlocks waiting on it. These
  functions are pure so the orchestration layer (e.g. `ReqManagedAgents.Session`)
  or any custom loop can call them.
  """

  @doc "Split `events` into the ones not in `seen` and return the grown seen-set."
  @spec dedupe([map()], MapSet.t()) :: {[map()], MapSet.t()}
  def dedupe(events, %MapSet{} = seen) do
    {fresh, seen} =
      Enum.reduce(events, {[], seen}, fn ev, {acc, seen} ->
        id = ev["id"]

        cond do
          is_nil(id) -> {[ev | acc], seen}
          MapSet.member?(seen, id) -> {acc, seen}
          true -> {[ev | acc], MapSet.put(seen, id)}
        end
      end)

    {Enum.reverse(fresh), seen}
  end

  @doc "Return `agent.custom_tool_use` events that have no matching `user.custom_tool_result`."
  @spec unanswered_tool_uses([map()]) :: [map()]
  def unanswered_tool_uses(history) do
    answered =
      for %{"type" => "user.custom_tool_result", "custom_tool_use_id" => id} <- history,
          into: MapSet.new(),
          do: id

    for %{"type" => "agent.custom_tool_use", "id" => id} = ev <- history,
        not MapSet.member?(answered, id),
        do: ev
  end

  @doc """
  Return the `stop_reason` map of the last `requires_action` idle event if it was
  never followed by another terminal idle (i.e. still pending), else `nil`.
  """
  @spec pending_requires_action([map()]) :: map() | nil
  def pending_requires_action(history) do
    history
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"type" => "session.status_idle", "stop_reason" => %{"type" => "requires_action"} = sr} ->
        sr

      %{"type" => "session.status_idle", "stop_reason" => %{"type" => _other}} ->
        :resolved

      _ ->
        nil
    end)
    |> case do
      :resolved -> nil
      other -> other
    end
  end
end
