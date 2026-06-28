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

  @spec invoke_to_completion(keyword()) :: {:ok, map()} | {:error, term()}
  def invoke_to_completion(opts) do
    handler = Keyword.fetch!(opts, :handler)
    context = opts[:context]
    sid = Keyword.fetch!(opts, :runtime_session_id)
    harness_id = Keyword.fetch!(opts, :harness_id)
    timeout = opts[:timeout] || 600_000
    invoke_fun = opts[:invoke_fun] || default_invoke_fun(opts)
    meta = opts[:telemetry_metadata] || %{}

    deadline = System.monotonic_time(:millisecond) + timeout
    user_msg = %{"role" => "user", "content" => [%{"text" => opts[:prompt] || "Begin."}]}

    loop(
      %{
        handler: handler,
        context: context,
        sid: sid,
        harness_id: harness_id,
        invoke_fun: invoke_fun,
        model: opts[:model],
        meta: meta,
        events: []
      },
      [user_msg],
      deadline
    )
  end

  defp loop(state, messages, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      inv = %{
        harness_id: state.harness_id,
        runtime_session_id: state.sid,
        messages: messages,
        model: state.model,
        handler: state.handler,
        context: state.context
      }

      case state.invoke_fun.(inv) do
        {:ok, events} ->
          parsed = Converse.parse(events)
          state = %{state | events: state.events ++ events}
          handle(state, parsed, deadline)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

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
  defp terminal_atom(_other), do: :end_turn

  defp default_invoke_fun(opts) do
    client = opts[:client] || Client.new()
    fn inv -> Client.invoke_harness(client, inv) end
  end
end
