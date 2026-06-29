defmodule ReqManagedAgents.AgentCore do
  @moduledoc """
  Per-turn invoke/resume driver for an AWS AgentCore Harness. Unlike
  `RunToCompletion` (a long-lived SSE session), Harness is request/response per
  turn: invoke → on `stopReason: "tool_use"` run the inline tools locally via
  `Tools.run` → resume with BOTH the assistant `toolUse` and user `toolResult`
  (the strict contract) on the same `runtimeSessionId` → loop until a normal
  terminal or timeout. Returns `{:ok, %{terminal, stop_reason, events}}` — the
  same shape `run_to_completion/1` returns, so app-side result mapping is symmetric.

  `:invoke_fun` defaults to `AgentCore.Client.invoke_harness/2`-backed and is an
  injectable test seam.
  """
  alias ReqManagedAgents.AgentCore.{Client, Converse}
  alias ReqManagedAgents.Tools

  require Logger

  # Extra attempts per turn on a transport error or a truncated stream (see
  # invoke_turn/3). The long data-plane InvokeHarness stream occasionally drops
  # mid-flight; a turn carries no irreversible local side effect until its tools
  # run, so re-invoking the same messages on the same session is safe.
  @invoke_retries 2

  @doc """
  Drive an AgentCore Harness to completion: invoke → on `tool_use` run inline tools
  via `:handler` → resume with BOTH the assistant `toolUse` and user `toolResult` →
  loop until a terminal stop or a stopping condition.

  **Required opts:** `:handler` — `(name, input, ctx) -> {:ok, text} | {:error, text}`;
  `:harness_arn`; `:runtime_session_id`.

  **Optional opts:**
  - `:prompt` — initial user message text (default `"Begin."`).
  - `:context` — forwarded to `:handler` on every tool call.
  - `:max_turns` — max `invoke_fun` calls (one per loop iteration); returns
    `{:error, {:max_turns_exceeded, max_turns}}` when exceeded (default 50).
  - `:timeout` — milliseconds (default 600_000). Checked at each loop entry.
  - `:invoke_fun` — injectable test seam; defaults to `AgentCore.Client.invoke_harness/2`.
  - `:model`, `:telemetry_metadata` — forwarded to the client / telemetry span.

  Returns `{:ok, %{terminal: atom(), stop_reason: String.t(), events: [map()]}}` on
  clean exit or `{:error, reason}` on timeout, max-turns exceeded, or a client error.
  `terminal: :end_turn` = clean stop; `terminal: :terminated` = abnormal or unknown stop
  (`:max_tokens`, `:guardrail_intervened`, or any unrecognised stop reason).
  """
  @spec invoke_to_completion(keyword()) :: {:ok, map()} | {:error, term()}
  def invoke_to_completion(opts) do
    handler = Keyword.fetch!(opts, :handler)
    context = opts[:context]
    sid = Keyword.fetch!(opts, :runtime_session_id)
    harness_arn = Keyword.fetch!(opts, :harness_arn)
    timeout = opts[:timeout] || 600_000
    max_turns = opts[:max_turns] || 50
    invoke_fun = opts[:invoke_fun] || default_invoke_fun(opts)
    invoke_retries = opts[:invoke_retries] || @invoke_retries
    meta = opts[:telemetry_metadata] || %{}

    deadline = System.monotonic_time(:millisecond) + timeout
    user_msg = %{"role" => "user", "content" => [%{"text" => opts[:prompt] || "Begin."}]}

    loop(
      %{
        handler: handler,
        context: context,
        sid: sid,
        harness_arn: harness_arn,
        invoke_fun: invoke_fun,
        invoke_retries: invoke_retries,
        model: opts[:model],
        meta: meta,
        events: [],
        turns: 0,
        max_turns: max_turns
      },
      [user_msg],
      deadline
    )
  end

  defp loop(state, messages, deadline) do
    cond do
      state.turns >= state.max_turns ->
        {:error, {:max_turns_exceeded, state.max_turns}}

      # Deadline is checked at iteration entry; a single slow invoke_fun call can
      # overshoot by up to the client's receive_timeout (soft ceiling, not hard).
      System.monotonic_time(:millisecond) > deadline ->
        {:error, :timeout}

      true ->
        state = %{state | turns: state.turns + 1}

        inv = %{
          harness_arn: state.harness_arn,
          runtime_session_id: state.sid,
          messages: messages,
          model: state.model,
          handler: state.handler,
          context: state.context
        }

        case invoke_turn(state, inv, state.invoke_retries) do
          {:ok, events, parsed} ->
            state = %{state | events: state.events ++ events}
            handle(state, parsed, deadline)

          # A truncation that survived the retry — NOT a transient drop. Surface a
          # distinct, diagnosable error instead of a soft terminal (:terminated/nil).
          {:early_termination, _events, _parsed} ->
            {:error, :early_termination}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # One turn with bounded retry. Three distinct outcomes by class:
  #   * a surfaced AWS exception/error frame (EventStream tags it __stream_error__) →
  #     {:error, {:harness_stream_error, type, message}} — a server-side close (e.g. a
  #     ConverseStream ValidationException), never retried, never a soft terminal;
  #   * a transport error OR a truncated stream (stop_reason == nil — the response ended
  #     without a messageStop) → retried (bounded); a transient drop resolves here;
  #   * retries exhausted on a still-truncated stream → {:early_termination, ...} so the
  #     loop surfaces {:error, :early_termination} (distinct from a real terminal).
  # Partial events from a dropped attempt are discarded; only the final attempt's events
  # are returned. A real-but-unknown stop reason ("content_blocked") IS a terminal.
  defp invoke_turn(state, inv, retries_left) do
    case state.invoke_fun.(inv) do
      {:ok, events} ->
        case stream_error(events) do
          {type, message} ->
            {:error, {:harness_stream_error, type, message}}

          nil ->
            parsed = Converse.parse(events)
            emit_tool_use_telemetry(state, parsed)

            cond do
              parsed.stop_reason != nil -> {:ok, events, parsed}
              retries_left > 0 -> invoke_turn(state, inv, retries_left - 1)
              true -> {:early_termination, events, parsed}
            end
        end

      {:error, _reason} when retries_left > 0 ->
        invoke_turn(state, inv, retries_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A surfaced AWS exception/error frame, if any (EventStream tags it __stream_error__).
  # Returns {type, message} — message flattened to the human string when present.
  defp stream_error(events) do
    Enum.find_value(events, fn
      %{"__stream_error__" => %{"type" => t, "message" => m}} -> {t, stream_error_message(m)}
      _ -> nil
    end)
  end

  defp stream_error_message(%{"message" => msg}) when is_binary(msg), do: msg
  defp stream_error_message(other), do: other

  defp handle(state, %{stop_reason: "tool_use", tool_uses: tool_uses}, deadline) do
    results =
      Enum.map(tool_uses, fn %{"toolUseId" => id, "name" => name, "input" => input} ->
        event = Tools.run(state.handler, id, name, input, state.context, state.meta)
        # Tools.run returns Event.custom_tool_result/3 where "content" is
        # [%{"type" => "text", "text" => text}] — extract the text from the head.
        text = get_in(event, ["content", Access.at(0), "text"]) || ""
        %{tool_use_id: id, text: text, is_error: event["is_error"] == true}
      end)

    resume = Converse.resume_messages(tool_uses, results)
    loop(state, resume, deadline)
  end

  defp handle(state, %{stop_reason: reason}, _deadline) do
    terminal = terminal_atom(reason)

    :telemetry.execute(
      [:req_managed_agents, :agent_core, :terminal],
      %{},
      Map.put(state.meta, :terminal, terminal)
    )

    {:ok, %{terminal: terminal, stop_reason: reason, events: state.events}}
  end

  defp terminal_atom("end_turn"), do: :end_turn
  defp terminal_atom("stop_sequence"), do: :end_turn
  defp terminal_atom("max_tokens"), do: :terminated
  defp terminal_atom("guardrail_intervened"), do: :terminated
  defp terminal_atom(_other), do: :terminated

  # Per-turn tool-use telemetry, plus a regression sentinel for MIM-52: `Converse.parse/1`
  # keys tool blocks by toolUseId, so its output is unique by construction. If a duplicate
  # ever reaches here again, surface it loudly — a duplicate toolUseId in the resume makes
  # Bedrock reject the NEXT turn with an opaque ConverseStream ValidationException.
  defp emit_tool_use_telemetry(state, parsed) do
    ids = Enum.map(parsed.tool_uses, & &1["toolUseId"])
    duplicate_ids = ids -- Enum.uniq(ids)

    :telemetry.execute(
      [:req_managed_agents, :agent_core, :tool_uses],
      %{tool_use_count: length(ids)},
      Map.merge(state.meta, %{turn: state.turns, tool_use_ids: ids})
    )

    if duplicate_ids != [] do
      Logger.warning(
        "duplicate toolUseId from parse/1 at turn #{state.turns}: " <>
          "#{inspect(duplicate_ids)} (ids=#{inspect(ids)}) — MIM-52 regression"
      )
    end

    :ok
  end

  defp default_invoke_fun(opts) do
    client = opts[:client] || Client.new()
    fn inv -> Client.invoke_harness(client, inv) end
  end
end
