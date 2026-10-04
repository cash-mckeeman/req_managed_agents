# QA-CHECKPOINT capture (run as an ExUnit test so Bypass works).
#
# Runs a fixed set of canonical scenarios through the PUBLIC FACADE
# (`ReqManagedAgents.run_to_completion/1` and `ReqManagedAgents.AgentCore.invoke_to_completion/1`)
# and writes a deterministic JSON fingerprint of each scenario's observable behavior to $QA_OUT.
#
# It uses ONLY the facade + deterministic transports (the Bedrock `invoke_fun` seam and a Bypass
# stub for the Claude SSE stream), so it produces IDENTICAL output whether the codebase is at
# PR11 (the three old drivers) or PR13 (the unified Session). That equality is the canonical
# proof the refactor changed no observable behavior. Driven by `mix req_managed_agents.qa_checkpoint`.
#
# Run directly: QA_OUT=/tmp/fp.json mix test qa/checkpoint_capture_test.exs

defmodule QA.CheckpointCaptureTest do
  use ExUnit.Case, async: false

  test "capture canonical behavior fingerprint" do
    scenarios = Enum.map(bedrock_scenarios(), &run_bedrock/1) ++ Enum.map(claude_scenarios(), &run_claude/1)
    out = System.get_env("QA_OUT") || "qa_fingerprint.json"
    File.write!(out, Jason.encode!(%{scenarios: scenarios}))
  end

  # ── canonical observable fingerprint of one scenario ────────────────────────────────
  defp fingerprint(name, provider, result, tool_calls) do
    {tag, terminal, stop_type, raw_kind, n_events, error} =
      case result do
        {:ok, %{terminal: t, stop_reason: sr, events: ev}} ->
          {"ok", to_string(t), stop_reason_type(sr), stop_reason_kind(sr), length(ev), nil}

        {:error, reason} ->
          {"error", nil, nil, nil, nil, inspect(reason)}
      end

    %{
      scenario: name,
      provider: provider,
      # ── compared for pass/fail (behavioral equivalence) ──
      result: tag,
      terminal: terminal,
      # normalized so PR11's map stop_reason and PR13's string stop_reason compare equal
      stop_reason_type: stop_type,
      tool_calls: tool_calls,
      n_final_events: n_events,
      error: error,
      # ── informational only, allow-listed (the documented map→string change) ──
      stop_reason_raw_kind: raw_kind
    }
  end

  # PR11 (Claude) returns the raw map %{"type" => "end_turn"}; PR13 returns the string "end_turn";
  # AgentCore always returns a string. Normalize all three to the comparable type string.
  defp stop_reason_type(%{"type" => t}), do: t
  defp stop_reason_type(s) when is_binary(s), do: s
  defp stop_reason_type(nil), do: nil

  # The raw representation (NOT compared for pass/fail) — surfaces the documented Claude change.
  defp stop_reason_kind(sr) when is_map(sr), do: "map"
  defp stop_reason_kind(sr) when is_binary(sr), do: "string"
  defp stop_reason_kind(_), do: nil

  # ── Bedrock (request_response) via the invoke_fun seam — no network ──────────────────
  defp tool_use_events(idx, id, name, input) do
    [
      %{"contentBlockStart" => %{"contentBlockIndex" => idx, "start" => %{"toolUse" => %{"toolUseId" => id, "name" => name}}}},
      %{"contentBlockDelta" => %{"contentBlockIndex" => idx, "delta" => %{"toolUse" => %{"input" => Jason.encode!(input)}}}}
    ]
  end

  defp message_stop(reason), do: %{"messageStop" => %{"stopReason" => reason}}

  defp bedrock_scenarios do
    [
      {"bedrock/end_turn", [[message_stop("end_turn")]]},
      {"bedrock/single_tool",
       [tool_use_events(0, "t1", "echo", %{"x" => 1}) ++ [message_stop("tool_use")], [message_stop("end_turn")]]},
      {"bedrock/multi_tool",
       [tool_use_events(0, "t1", "a", %{"n" => 1}) ++ tool_use_events(1, "t2", "b", %{"n" => 2}) ++ [message_stop("tool_use")],
        [message_stop("end_turn")]]},
      {"bedrock/stream_error", [[%{"__stream_error__" => %{"type" => "ValidationException", "message" => "boom"}}]]}
    ]
  end

  defp run_bedrock({name, turns}) do
    {:ok, script} = Agent.start_link(fn -> turns end)
    {:ok, calls} = Agent.start_link(fn -> [] end)

    handler = fn n, i, _ctx ->
      Agent.update(calls, &[%{name: n, input: i} | &1])
      {:ok, "result:#{n}"}
    end

    invoke_fun = fn _inv ->
      events =
        Agent.get_and_update(script, fn
          [t | rest] -> {t, rest}
          [] -> {[message_stop("end_turn")], []}
        end)

      {:ok, events}
    end

    result =
      ReqManagedAgents.AgentCore.invoke_to_completion(
        harness_arn: "arn:aws:bedrock-agentcore:us-east-1:0:harness/qa",
        runtime_session_id: String.duplicate("q", 33),
        handler: handler,
        invoke_fun: invoke_fun,
        max_turns: 10,
        timeout: 5_000
      )

    fingerprint(name, "bedrock", result, tool_call_names(calls))
  end

  # ── Claude (streaming) via a Bypass stub of the control plane + SSE stream ───────────
  defp sse(events) do
    Enum.map_join(events, "", fn ev -> "event: #{ev["type"]}\ndata: #{Jason.encode!(ev)}\n\n" end)
  end

  defp custom_tool_use(id, name, input),
    do: %{"type" => "agent.custom_tool_use", "id" => id, "name" => name, "input" => input}

  defp requires_action(ids),
    do: %{"type" => "session.status_idle", "stop_reason" => %{"type" => "requires_action", "event_ids" => ids}}

  defp end_turn_idle, do: %{"type" => "session.status_idle", "stop_reason" => %{"type" => "end_turn"}}

  defp claude_scenarios do
    [
      {"claude/end_turn", [[end_turn_idle()]], :ok},
      {"claude/single_tool",
       [[custom_tool_use("u1", "lookup", %{"q" => 1})], [requires_action(["u1"])], [end_turn_idle()]], :ok},
      {"claude/handler_error",
       [[custom_tool_use("u1", "boom", %{})], [requires_action(["u1"])], [end_turn_idle()]], :error_handler}
    ]
  end

  defp run_claude({name, chunks, mode}) do
    bypass = Bypass.open()
    client = ReqManagedAgents.Client.new(api_key: "sk-qa", base_url: "http://localhost:#{bypass.port}")
    {:ok, calls} = Agent.start_link(fn -> [] end)
    sid = "qa-#{:erlang.phash2(name)}"

    Bypass.expect_once(bypass, "POST", "/v1/sessions", fn conn -> Req.Test.json(conn, %{"id" => sid}) end)

    Bypass.expect_once(bypass, "GET", "/v1/sessions/#{sid}/events/stream", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(chunks, conn, fn chunk, conn ->
        Process.sleep(30)
        {:ok, conn} = Plug.Conn.chunk(conn, sse(chunk))
        conn
      end)

      conn
    end)

    Bypass.stub(bypass, "POST", "/v1/sessions/#{sid}/events", fn conn -> Req.Test.json(conn, %{"ok" => true}) end)

    handler = fn n, i, _ctx ->
      Agent.update(calls, &[%{name: n, input: i} | &1])
      if mode == :error_handler, do: {:error, "tool failed"}, else: {:ok, "result:#{n}"}
    end

    result =
      ReqManagedAgents.run_to_completion(
        client: client,
        agent_id: "qa-agent",
        environment_id: "qa-env",
        prompt: "go",
        handler: handler,
        timeout: 5_000
      )

    fingerprint(name, "claude", result, tool_call_names(calls))
  end

  defp tool_call_names(agent), do: agent |> Agent.get(& &1) |> Enum.reverse() |> Enum.map(& &1.name)
end
