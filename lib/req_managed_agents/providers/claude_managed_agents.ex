defmodule ReqManagedAgents.Providers.ClaudeManagedAgents do
  @moduledoc """
  `ReqManagedAgents.Provider` for the Anthropic Managed Agents backend — `:streaming` mode.
  A long-lived SSE stream pushes events; the client POSTs events to drive it; a turn ends on
  `session.status_idle`. Resume POSTs a `user.custom_tool_result` event (no echo — the session
  already holds the tool call). Composes `Client`, `Stream`, `Event`.

  `normalize/1` keys off the most recent status event. `events`, `text`, and `server_tool_uses`
  reflect exactly the events passed in (a partial list yields a partial view).

  A `model_config: %{api_key:, base_url:}` opt builds the client when no `:client` is injected — the canonical way to run a session on a granted key + routed base_url.
  """
  @behaviour ReqManagedAgents.Provider

  alias ReqManagedAgents.Agent.Spec
  alias ReqManagedAgents.{Client, Event, Outcome, Stream, ToolUse, TurnResult, Usage}

  @impl true
  def mode, do: :streaming

  @impl true
  def provision(spec, opts) do
    client = client_from(opts)
    name = opts[:name] || "agent_" <> agent_digest(spec)

    agent_body = %{
      name: name,
      model: spec.model_config,
      system: spec.system_prompt,
      tools: spec.tools
    }

    env_body =
      opts[:environment] ||
        %{name: "#{name}_env", config: %{type: "cloud", networking: %{type: "unrestricted"}}}

    with {:ok, %{"id" => agent_id}} <- Client.create_agent(client, agent_body) do
      case Client.create_environment(client, env_body) do
        {:ok, %{"id" => env_id}} ->
          {:ok, %{agent_id: agent_id, environment_id: env_id}}

        {:error, reason} ->
          # Roll back the orphaned agent so nothing leaks and a retry isn't blocked.
          _ = Client.archive_agent(client, agent_id)
          {:error, reason}

        other ->
          _ = Client.archive_agent(client, agent_id)
          {:error, {:unexpected_create_environment_response, other}}
      end
    end
  end

  @impl true
  def teardown(%{agent_id: aid, environment_id: eid}, opts) do
    client = client_from(opts)
    # Attempt both archives unconditionally — a failure archiving one must not strand the other.
    a = Client.archive_agent(client, aid)
    e = Client.archive_environment(client, eid)

    case {a, e} do
      {{:ok, _}, {:ok, _}} -> :ok
      _ -> {:error, {:teardown_failed, %{agent: archive_tag(a), environment: archive_tag(e)}}}
    end
  end

  defp archive_tag({:ok, _}), do: :ok
  defp archive_tag({:error, reason}), do: {:error, reason}

  @impl true
  def open(opts, subscriber) do
    client = client_from(opts)

    case opts[:session_id] do
      nil ->
        body = %{
          agent: Keyword.fetch!(opts, :agent_id),
          environment_id: Keyword.fetch!(opts, :environment_id)
        }

        case Client.create_session(client, body) do
          {:ok, %{"id" => sid}} ->
            ref = make_ref()

            {:ok, task} =
              Task.start_link(fn ->
                Stream.stream(client, sid, subscriber,
                  ref: ref,
                  telemetry_metadata: opts[:telemetry_metadata] || %{}
                )
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
  def kickoff_input(opts) do
    case opts[:outcome] do
      nil ->
        [Event.user_message(opts[:prompt] || "Begin.")]

      raw ->
        # The :outcome is validated at session start (Outcome.new/1), so coercing
        # here is total; matching the struct by name keeps the wire hand-off explicit.
        {:ok, %Outcome{description: d, rubric: r, max_iterations: n}} = Outcome.new(raw)
        [Event.define_outcome(d, r, max_iterations: n)]
    end
  end

  @impl true
  def supports_outcomes?, do: true

  @impl true
  def user_input(text), do: [Event.user_message(text)]

  @impl true
  def resume_input(_custom_tool_uses, results) do
    Enum.map(results, fn r ->
      Event.custom_tool_result(r.tool_use_id, r.text, is_error: r.is_error)
    end)
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
        pending = pending_tool_uses(past)

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
  # Same recovery reconnect/3 does for a stream drop, but keyed off the events the Session
  # already holds in memory (no extra round trip): a `requires_action` batch that resolves
  # to zero `custom_tool_uses` means the ids its idle references live in an earlier batch —
  # find them the same way (unanswered agent.custom_tool_use, by history) and let Session
  # re-run + resume them instead of ever driving an empty resume (issue #61).
  def pending_tool_uses(events) do
    events
    |> ReqManagedAgents.Consolidate.unanswered_tool_uses()
    |> Enum.map(fn e -> %ToolUse{id: e["id"], name: e["name"], input: e["input"]} end)
  end

  @impl true
  def text_delta(%{"type" => "agent.message", "content" => blocks}) when is_list(blocks) do
    case for(%{"type" => "text", "text" => t} <- blocks, is_binary(t), do: t) do
      [] -> nil
      texts -> Enum.join(texts)
    end
  end

  def text_delta(_), do: nil

  @impl true
  def normalize(events) do
    uses_by_id =
      for %{"type" => "agent.custom_tool_use", "id" => id} = e <- events, into: %{}, do: {id, e}

    case latest_status(events) do
      %{"type" => "session.status_idle", "stop_reason" => %{"type" => reason} = sr} ->
        custom =
          sr
          |> Map.get("event_ids", [])
          |> Enum.map(&uses_by_id[&1])
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn e ->
            %ToolUse{id: e["id"], name: e["name"], input: e["input"] || %{}}
          end)

        turn_result(terminal(reason), sr, custom, events)

      %{"type" => "session.status_terminated"} = s ->
        turn_result(:terminated, s["stop_reason"], [], events)

      %{"type" => "session.error"} = s ->
        turn_result(:terminated, s["stop_reason"], [], events)

      %{"type" => "session.status_idle"} = s ->
        turn_result(:terminated, s["stop_reason"], [], events)

      _ ->
        turn_result(:terminated, nil, [], events)
    end
  end

  defp turn_result(terminal, stop_reason, custom_tool_uses, events) do
    %TurnResult{
      terminal: terminal,
      stop_reason: stop_reason,
      text: assistant_text(events),
      custom_tool_uses: custom_tool_uses,
      server_tool_uses: server_tool_uses(events),
      usage: claude_usage(events),
      events: events
    }
  end

  # Managed Agents reports token usage on each `span.model_request_end` event under `model_usage`
  # (a turn may make several model requests — sum them). Confirmed against a live
  # consumer (chat_handler.ex); Anthropic's snake_case `input_tokens`/`output_tokens`.
  defp claude_usage(events) do
    usages =
      for %{"type" => "span.model_request_end"} = ev <- events,
          u = ev["model_usage"] || ev["usage"],
          is_map(u),
          do: u

    case usages do
      [] ->
        nil

      list ->
        %Usage{
          input_tokens: Enum.sum(Enum.map(list, &(&1["input_tokens"] || 0))),
          output_tokens: Enum.sum(Enum.map(list, &(&1["output_tokens"] || 0))),
          raw: list
        }
    end
  end

  @doc false
  def terminal("end_turn"), do: :end_turn
  def terminal("requires_action"), do: :requires_action
  # Outcome sessions (user.define_outcome): the server-side grade→revise loop resolves to one
  # of these at status_idle. satisfied / max_iterations_reached complete the run; failed doesn't.
  def terminal("satisfied"), do: :end_turn
  def terminal("max_iterations_reached"), do: :end_turn
  def terminal("failed"), do: :terminated
  def terminal(_other), do: :terminated

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
        do: %ToolUse{id: e["id"], name: name, input: e["input"] || %{}}
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

  # Canonical model_config keys (:api_key, :base_url) build the client when no
  # explicit :client is injected — this is how a granted key + routed base_url
  # reach a session on this provider. Only the client-relevant keys are taken;
  # :model/:metadata stay opaque to this provider.
  defp client_from(opts) do
    case opts[:client] do
      nil ->
        config = opts[:model_config] || %{}
        Client.new(config |> Map.take([:api_key, :base_url]) |> Map.to_list())

      client ->
        client
    end
  end

  # Same content-address as `Agent.Spec.digest/1` (env-agent naming, Bedrock's harness_name) —
  # one digest source across all providers so identical content always names identically.
  defp agent_digest(spec) do
    {:ok, s} = Spec.new(Map.put_new(spec, :name, "agent"))
    Spec.digest(s)
  end
end
