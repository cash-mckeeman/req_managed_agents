defmodule ReqManagedAgents.Providers.LocalTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Providers.Local
  alias ReqManagedAgents.{ToolResult, ToolUse, TurnResult, Usage}

  @spec_map %{
    system_prompt: "You are terse.",
    tools: [
      %{"name" => "lookup", "description" => "Look up", "input_schema" => %{"type" => "object"}}
    ],
    terminal_tool: nil,
    model_config: %{model: "test:model"}
  }

  defp scripted(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn request ->
      fun = Agent.get_and_update(agent, fn [r | rest] -> {r, rest} end)
      fun.(request)
    end
  end

  # A response fun gets the request (for assertions) and returns {:ok, response}.
  defp text_response(text) do
    fn _req ->
      {:ok,
       %{
         "choices" => [
           %{"message" => %{"role" => "assistant", "content" => text}, "finish_reason" => "stop"}
         ],
         "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
       }}
    end
  end

  defp tool_call_response(id, name, args_json) do
    fn _req ->
      {:ok,
       %{
         "choices" => [
           %{
             "message" => %{
               "role" => "assistant",
               "content" => nil,
               "tool_calls" => [
                 %{
                   "id" => id,
                   "type" => "function",
                   "function" => %{"name" => name, "arguments" => args_json}
                 }
               ]
             },
             "finish_reason" => "tool_calls"
           }
         ],
         "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 8}
       }}
    end
  end

  defp open!(chat_fun, extra \\ []) do
    {:ok, conn} =
      Local.open([spec: @spec_map, chat_fun: chat_fun, prompt: "hi"] ++ extra, self())

    conn
  end

  test "open/2 builds the conn: system prompt, converted tools, minted session_id" do
    conn = open!(fn _ -> {:ok, %{}} end)

    assert [%{"role" => "system", "content" => "You are terse."}] = conn.history
    assert [%{"type" => "function", "function" => %{"name" => "lookup"}}] = conn.tools
    assert "local_" <> _ = conn.session_id
  end

  test "poll_turn: kickoff appends the user message and returns local.model_response events" do
    test = self()

    chat_fun = fn request ->
      send(test, {:chat_request, request})
      text_response("hello").(request)
    end

    conn = open!(chat_fun)

    assert {:ok, events, conn2} = Local.poll_turn(conn, Local.kickoff_input(prompt: "hi"))

    assert_received {:chat_request, %{model: "test:model", messages: messages, tools: [_]}}
    assert [%{"role" => "system"}, %{"role" => "user", "content" => "hi"}] = messages

    assert [%{"type" => "local.model_response", "finish_reason" => "stop"} = ev] = events
    assert ev["message"]["content"] == "hello"

    # history grew: system, user, assistant
    assert [_, _, %{"role" => "assistant", "content" => "hello"}] = conn2.history
  end

  test "normalize: stop → :end_turn with text and usage" do
    conn = open!(scripted([text_response("done!")]))
    {:ok, events, _} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))

    assert %TurnResult{
             terminal: :end_turn,
             stop_reason: "stop",
             text: "done!",
             custom_tool_uses: [],
             usage: %Usage{input_tokens: 10, output_tokens: 5, raw: [_]},
             events: ^events
           } = Local.normalize(events)
  end

  test "normalize: tool_calls → :requires_action with decoded ToolUse" do
    conn = open!(scripted([tool_call_response("c1", "lookup", ~s({"q":"x"}))]))
    {:ok, events, _} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))

    assert %TurnResult{
             terminal: :requires_action,
             custom_tool_uses: [%ToolUse{id: "c1", name: "lookup", input: %{"q" => "x"}}]
           } = Local.normalize(events)
  end

  test "resume appends tool results then calls the model again" do
    test = self()

    second = fn request ->
      send(test, {:second_request, request})
      text_response("after tools").(request)
    end

    conn = open!(scripted([tool_call_response("c1", "lookup", "{}"), second]))
    {:ok, _events, conn} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))

    uses = [%ToolUse{id: "c1", name: "lookup", input: %{}}]
    results = [%ToolResult{tool_use_id: "c1", text: "found it", is_error: false}]

    assert {:ok, events, _conn} = Local.poll_turn(conn, Local.resume_input(uses, results))

    assert_received {:second_request, %{messages: messages}}

    assert %{"role" => "tool", "tool_call_id" => "c1", "content" => "found it"} =
             Enum.find(messages, &(&1["role"] == "tool"))

    assert [%{"type" => "local.model_response"}] = events
  end

  test "error tool results are JSON-tagged" do
    test = self()

    second = fn request ->
      send(test, {:second_request, request})
      text_response("ok").(request)
    end

    conn = open!(scripted([tool_call_response("c1", "lookup", "{}"), second]))
    {:ok, _, conn} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))

    uses = [%ToolUse{id: "c1", name: "lookup", input: %{}}]
    results = [%ToolResult{tool_use_id: "c1", text: "boom", is_error: true}]
    {:ok, _, _} = Local.poll_turn(conn, Local.resume_input(uses, results))

    assert_received {:second_request, %{messages: messages}}
    tool_msg = Enum.find(messages, &(&1["role"] == "tool"))
    assert Jason.decode!(tool_msg["content"]) == %{"error" => "boom", "isError" => true}
  end

  test "chat_fun error surfaces as {:error, reason}" do
    conn = open!(fn _ -> {:error, %{status: 401}} end)
    assert {:error, %{status: 401}} = Local.poll_turn(conn, Local.kickoff_input(prompt: "x"))
  end

  test "non-empty tool_calls win over finish_reason stop (some servers send both)" do
    resp = fn _req ->
      {:ok,
       %{
         "choices" => [
           %{
             "message" => %{
               "role" => "assistant",
               "content" => nil,
               "tool_calls" => [
                 %{
                   "id" => "c9",
                   "type" => "function",
                   "function" => %{"name" => "lookup", "arguments" => "{}"}
                 }
               ]
             },
             "finish_reason" => "stop"
           }
         ],
         "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
       }}
    end

    conn = open!(scripted([resp]))
    {:ok, events, _} = Local.poll_turn(conn, Local.kickoff_input(prompt: "x"))

    assert %TurnResult{terminal: :requires_action, custom_tool_uses: [%ToolUse{id: "c9"}]} =
             Local.normalize(events)
  end

  test "finish_reason length → :terminated" do
    resp = fn _req ->
      {:ok,
       %{
         "choices" => [
           %{
             "message" => %{"role" => "assistant", "content" => "trunc"},
             "finish_reason" => "length"
           }
         ],
         "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
       }}
    end

    conn = open!(scripted([resp]))
    {:ok, events, _} = Local.poll_turn(conn, Local.kickoff_input(prompt: "x"))
    assert %TurnResult{terminal: :terminated, stop_reason: "length"} = Local.normalize(events)
  end

  test "provision/teardown: identity handle, nothing server-side" do
    assert {:ok, @spec_map} = Local.provision(@spec_map, [])
    assert :ok = Local.teardown(@spec_map, [])
  end

  test "text_delta/1 maps local.model_response content" do
    ev = %{"type" => "local.model_response", "message" => %{"content" => "chunk"}}
    assert Local.text_delta(ev) == "chunk"

    assert Local.text_delta(%{"type" => "local.model_response", "message" => %{"content" => nil}}) ==
             nil

    assert Local.text_delta(%{"type" => "other"}) == nil
  end

  test "normalize: null prompt_tokens in usage yields usage: nil" do
    resp = fn _req ->
      {:ok,
       %{
         "choices" => [
           %{"message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}
         ],
         "usage" => %{"prompt_tokens" => nil, "completion_tokens" => nil}
       }}
    end

    conn = open!(scripted([resp]))
    {:ok, events, _} = Local.poll_turn(conn, Local.kickoff_input(prompt: "x"))
    assert %TurnResult{usage: nil} = Local.normalize(events)
  end

  test "polls reset per request: a follow-up message does not fire final_turn early" do
    conn = open!(text_response("ok"), max_turns: 3)
    conn = %{conn | polls: 5}

    {:ok, events, conn2} = Local.poll_turn(conn, Local.user_input("follow up"))

    refute Enum.any?(events, &(&1["type"] == "local.directive" and &1["role"] == "final_turn"))
    assert conn2.polls == 1
  end

  test "seen resets per request: an identical tool call in a new request is not deduped" do
    test = self()
    args = ~s({"q":1})

    third = fn request ->
      send(test, {:third_request, request})
      tool_call_response("c2", "lookup", args).(request)
    end

    conn =
      open!(scripted([tool_call_response("c1", "lookup", args), text_response("done"), third]))

    {:ok, _ev1, conn} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))

    uses = [%ToolUse{id: "c1", name: "lookup", input: %{"q" => 1}}]
    results = [%ToolResult{tool_use_id: "c1", text: "found it", is_error: false}]
    {:ok, _ev2, conn} = Local.poll_turn(conn, Local.resume_input(uses, results))

    # New user turn: the same {name, input} call must NOT be treated as a duplicate,
    # because the dedup guard is per-request, not per-conn-lifetime.
    {:ok, ev3, _conn} = Local.poll_turn(conn, Local.user_input("again"))

    refute Enum.any?(ev3, &(&1["type"] == "local.duplicate_tool_call"))

    assert %TurnResult{terminal: :requires_action, custom_tool_uses: [%ToolUse{id: "c2"}]} =
             Local.normalize(ev3)
  end

  test "outcome kickoff is unsupported (Session gate)" do
    assert {:error, :outcome_unsupported} =
             ReqManagedAgents.Session.run(Local,
               handler: fn _, _, _ -> {:ok, ""} end,
               spec: @spec_map,
               chat_fun: fn _ -> {:ok, %{}} end,
               outcome: %{description: "d", rubric: "r"}
             )
  end
end
