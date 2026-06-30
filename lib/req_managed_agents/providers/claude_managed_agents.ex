defmodule ReqManagedAgents.Providers.ClaudeManagedAgents do
  @moduledoc """
  `ReqManagedAgents.Provider` for the Anthropic Managed Agents backend — `:streaming` mode.
  A long-lived SSE stream pushes events; the client POSTs events to drive it; a turn ends on
  `session.status_idle`. Resume POSTs a `user.custom_tool_result` event (no echo — the session
  already holds the tool call). Composes `Client`, `Stream`, `Event`.

  `normalize/1` keys off the most recent status event. `events`, `text`, and `server_tool_uses`
  reflect exactly the events passed in (a partial list yields a partial view).
  """
  @behaviour ReqManagedAgents.Provider

  alias ReqManagedAgents.{Client, Event, Stream}

  @impl true
  def mode, do: :streaming

  @impl true
  def open(opts, subscriber) do
    client = opts[:client] || Client.new()

    case opts[:session_id] do
      nil ->
        body = %{agent: Keyword.fetch!(opts, :agent_id), environment_id: Keyword.fetch!(opts, :environment_id)}

        case Client.create_session(client, body) do
          {:ok, %{"id" => sid}} ->
            ref = make_ref()

            {:ok, task} =
              Task.start_link(fn ->
                Stream.stream(client, sid, subscriber, ref: ref, telemetry_metadata: opts[:telemetry_metadata] || %{})
              end)

            {:ok, %{client: client, session_id: sid, ref: ref, consumer: task}}

          {:error, reason} ->
            {:error, {:create_session_failed, reason}}
        end

      sid ->
        # Resume an existing session: don't create or kick off — the Session consolidates via
        # reconnect/3 (list history, dedup, re-drive any unanswered tool call), opening the stream there.
        {:ok, %{client: client, session_id: sid, ref: nil, resume: true}}
    end
  end

  @impl true
  def kickoff_input(opts), do: [Event.user_message(opts[:prompt] || "Begin.")]

  @impl true
  def user_input(text), do: [Event.user_message(text)]

  @impl true
  def resume_input(_custom_tool_uses, results) do
    Enum.map(results, fn r -> Event.custom_tool_result(r.tool_use_id, r.text, is_error: r.is_error) end)
  end

  @impl true
  def push_input(conn, events) do
    case Client.send_events(conn.client, conn.session_id, events) do
      {:error, _} = err -> err
      _ok -> :ok
    end
  end

  @impl true
  def turn_boundary?(%{"type" => "session.status_idle"}), do: true
  def turn_boundary?(%{"type" => "session.status_terminated"}), do: true
  def turn_boundary?(%{"type" => "session.error"}), do: true
  def turn_boundary?(_), do: false

  @impl true
  def reconnect(conn, subscriber, seen) do
    # The event stream has no replay: on reconnect, list past events, grow the dedup set, and
    # recover any tool call left unanswered across the drop (the Session re-runs + resumes those).
    case Client.list_all_events(conn.client, conn.session_id) do
      {:ok, past} ->
        {_fresh, seen} = ReqManagedAgents.Consolidate.dedupe(past, seen)

        pending =
          past
          |> ReqManagedAgents.Consolidate.unanswered_tool_uses()
          |> Enum.map(fn e -> %{id: e["id"], name: e["name"], input: e["input"]} end)

        ref = make_ref()

        {:ok, task} =
          Task.start_link(fn ->
            Stream.stream(conn.client, conn.session_id, subscriber, ref: ref)
          end)

        {:ok, Map.merge(conn, %{ref: ref, consumer: task}), pending, seen}

      {:error, reason} ->
        {:error, reason}
    end
  end

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

      %{"type" => "session.status_terminated"} -> outcome(:terminated, "terminated", [], extra)
      %{"type" => "session.error"} -> outcome(:terminated, "error", [], extra)
      %{"type" => "session.status_idle"} -> outcome(:terminated, nil, [], extra)
      _ -> outcome(:terminated, nil, [], extra)
    end
  end

  @doc false
  def terminal("end_turn"), do: :end_turn
  def terminal("requires_action"), do: :requires_action
  def terminal(_other), do: :terminated

  defp outcome(terminal, reason, custom_tool_uses, extra),
    do: Map.merge(%{terminal: terminal, stop_reason: reason, custom_tool_uses: custom_tool_uses}, extra)

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

  defp server_tool_uses(events) do
    for %{"type" => "agent.tool_use", "name" => name} = e <- events,
        do: %{id: e["id"], name: name, input: e["input"] || %{}}
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
