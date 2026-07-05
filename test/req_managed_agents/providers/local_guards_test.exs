defmodule ReqManagedAgents.Providers.LocalGuardsTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Local.Directives
  alias ReqManagedAgents.Providers.Local
  alias ReqManagedAgents.{ToolResult, ToolUse, TurnResult}

  @spec_map %{
    system_prompt: "sys",
    tools: [%{"name" => "lookup", "description" => "", "input_schema" => %{}}],
    terminal_tool: "submit",
    model_config: %{model: "test:model"}
  }

  defp tool_call_resp(id, name, args_json) do
    {:ok,
     %{
       "choices" => [
         %{
           "message" => %{
             "role" => "assistant",
             "content" => nil,
             "tool_calls" => [
               %{"id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => args_json}}
             ]
           },
           "finish_reason" => "tool_calls"
         }
       ],
       "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
     }}
  end

  defp text_resp(text) do
    {:ok,
     %{
       "choices" => [
         %{"message" => %{"role" => "assistant", "content" => text}, "finish_reason" => "stop"}
       ],
       "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
     }}
  end

  defp scripted(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn request ->
      fun = Agent.get_and_update(agent, fn [r | rest] -> {r, rest} end)
      if is_function(fun), do: fun.(request), else: fun
    end
  end

  defp open!(chat_fun, extra \\ []) do
    {:ok, conn} = Local.open([spec: @spec_map, chat_fun: chat_fun] ++ extra, self())
    conn
  end

  # ── (a) duplicate-call dedup ──────────────────────────────────────────────────

  test "a repeated {name, input} call is self-answered, not re-surfaced" do
    test = self()

    third = fn request ->
      send(test, {:third_request, request})
      text_resp("done")
    end

    conn =
      open!(
        scripted([
          tool_call_resp("c1", "lookup", ~s({"q":1})),
          tool_call_resp("c2", "lookup", ~s({"q":1})),
          third
        ])
      )

    # Turn 1: fresh call surfaces normally.
    {:ok, ev1, conn} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))
    assert %TurnResult{terminal: :requires_action, custom_tool_uses: [%ToolUse{id: "c1"}]} =
             Local.normalize(ev1)

    # Resume with the result; the model repeats the SAME {name, input} (new id).
    uses = [%ToolUse{id: "c1", name: "lookup", input: %{"q" => 1}}]
    results = [%ToolResult{tool_use_id: "c1", text: "answer", is_error: false}]
    {:ok, ev2, conn} = Local.poll_turn(conn, Local.resume_input(uses, results))

    # The duplicate is NOT surfaced: requires_action with zero tool uses
    # (Session resumes empty; the provider already self-answered in history).
    tr2 = Local.normalize(ev2)
    assert %TurnResult{terminal: :requires_action, custom_tool_uses: []} = tr2
    assert Enum.any?(ev2, &(&1["type"] == "local.duplicate_tool_call"))

    # Empty resume → the model is called with the duplicate self-answer in history.
    {:ok, ev3, _conn} = Local.poll_turn(conn, Local.resume_input([], []))
    assert %TurnResult{terminal: :end_turn, text: "done"} = Local.normalize(ev3)

    assert_received {:third_request, %{messages: messages}}
    dup_msg = messages |> Enum.filter(&(&1["role"] == "tool")) |> List.last()
    decoded = Jason.decode!(dup_msg["content"])
    assert decoded["duplicate"] == true
    assert decoded["message"] == Directives.duplicate_tool()
  end

  # ── (b) consecutive-error correctives ────────────────────────────────────────

  test "two consecutive errors from the same tool inject the corrective directive" do
    test = self()

    third = fn request ->
      send(test, {:third_request, request})
      text_resp("gave up")
    end

    conn =
      open!(
        scripted([
          tool_call_resp("c1", "lookup", ~s({"q":1})),
          tool_call_resp("c2", "lookup", ~s({"q":2})),
          third
        ])
      )

    {:ok, _, conn} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))

    err = fn id -> [%ToolResult{tool_use_id: id, text: "bad input", is_error: true}] end
    use_ = fn id, q -> [%ToolUse{id: id, name: "lookup", input: %{"q" => q}}] end

    # First error: no directive yet.
    {:ok, _, conn} = Local.poll_turn(conn, Local.resume_input(use_.("c1", 1), err.("c1")))

    # Second consecutive error: corrective injected before the next model call.
    {:ok, ev, _conn} = Local.poll_turn(conn, Local.resume_input(use_.("c2", 2), err.("c2")))
    assert Enum.any?(ev, &(&1["type"] == "local.directive" and &1["role"] == "corrective"))

    assert_received {:third_request, %{messages: messages}}
    corrective = Directives.corrective("lookup", "bad input")
    assert Enum.any?(messages, &(&1["role"] == "user" and &1["content"] == corrective))
  end

  test "a success resets the tool's consecutive-error count" do
    conn =
      open!(
        scripted([
          tool_call_resp("c1", "lookup", ~s({"q":1})),
          tool_call_resp("c2", "lookup", ~s({"q":2})),
          tool_call_resp("c3", "lookup", ~s({"q":3})),
          fn _ -> text_resp("done") end
        ])
      )

    {:ok, _, conn} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))

    r = fn id, err? -> [%ToolResult{tool_use_id: id, text: "t", is_error: err?}] end
    u = fn id, q -> [%ToolUse{id: id, name: "lookup", input: %{"q" => q}}] end

    {:ok, _, conn} = Local.poll_turn(conn, Local.resume_input(u.("c1", 1), r.("c1", true)))
    {:ok, _, conn} = Local.poll_turn(conn, Local.resume_input(u.("c2", 2), r.("c2", false)))
    {:ok, ev, _} = Local.poll_turn(conn, Local.resume_input(u.("c3", 3), r.("c3", true)))

    # error → success → error is NOT two consecutive: no corrective.
    refute Enum.any?(ev, &(&1["type"] == "local.directive"))
  end

  # ── (c) final-turn directive ──────────────────────────────────────────────────

  test "the last allowed poll injects the final-turn directive" do
    test = self()

    second = fn request ->
      send(test, {:final_request, request})
      text_resp("final answer")
    end

    conn =
      open!(scripted([tool_call_resp("c1", "lookup", "{}"), second]), max_turns: 2)

    {:ok, ev1, conn} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))
    refute Enum.any?(ev1, &(&1["type"] == "local.directive"))

    uses = [%ToolUse{id: "c1", name: "lookup", input: %{}}]
    results = [%ToolResult{tool_use_id: "c1", text: "x", is_error: false}]
    {:ok, ev2, _} = Local.poll_turn(conn, Local.resume_input(uses, results))

    assert Enum.any?(ev2, &(&1["type"] == "local.directive" and &1["role"] == "final_turn"))

    assert_received {:final_request, %{messages: messages}}
    directive = Directives.final_turn("submit")
    assert Enum.any?(messages, &(&1["role"] == "user" and &1["content"] == directive))
  end

  test "full Session.run: kickoff → tool → resume → end_turn through Local" do
    test = self()

    chat_fun =
      scripted([
        tool_call_resp("c1", "lookup", ~s({"q":"x"})),
        fn _ -> text_resp("the answer") end
      ])

    handler = fn name, input, _ctx ->
      send(test, {:tool_ran, name, input})
      {:ok, "found"}
    end

    assert {:ok, result} =
             ReqManagedAgents.Session.run(ReqManagedAgents.Providers.Local,
               handler: handler,
               spec: @spec_map,
               chat_fun: chat_fun,
               prompt: "question?"
             )

    assert result.terminal == :end_turn
    assert result.text == "the answer"
    assert result.turns == 2
    assert [%ToolUse{name: "lookup"}] = result.custom_tool_uses
    assert result.session_id =~ "local_"
    assert_received {:tool_ran, "lookup", %{"q" => "x"}}
    assert Enum.count(result.events, &(&1["type"] == "local.model_response")) == 2
  end
end
