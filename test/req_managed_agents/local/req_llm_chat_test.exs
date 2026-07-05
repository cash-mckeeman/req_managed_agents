defmodule ReqManagedAgents.Local.ReqLLMChatTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Local.ReqLLMChat

  @request %{
    model: "openai:gpt-test",
    messages: [
      %{"role" => "system", "content" => "sys"},
      %{"role" => "user", "content" => "hi"},
      %{
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          %{
            "id" => "c1",
            "type" => "function",
            "function" => %{"name" => "lookup", "arguments" => ~s({"q":1})}
          }
        ]
      },
      %{"role" => "tool", "tool_call_id" => "c1", "content" => "found"}
    ],
    tools: [
      %{
        "type" => "function",
        "function" => %{
          "name" => "lookup",
          "description" => "d",
          "parameters" => %{"type" => "object"}
        }
      }
    ]
  }

  test "to_context/1 converts every neutral role" do
    ctx = ReqLLMChat.to_context(@request.messages)
    assert %ReqLLM.Context{messages: [sys, user, assistant, tool]} = ctx
    assert sys.role == :system
    assert user.role == :user
    assert assistant.role == :assistant
    assert [%ReqLLM.ToolCall{id: "c1", function: %{name: "lookup"}}] = assistant.tool_calls
    assert tool.role == :tool
  end

  test "to_tools/1 converts function declarations" do
    assert [%ReqLLM.Tool{name: "lookup", description: "d"}] = ReqLLMChat.to_tools(@request.tools)
  end

  test "model_term/2 threads base_url through the model map" do
    assert "openai:gpt-test" = ReqLLMChat.model_term("openai:gpt-test", %{})

    assert %{provider: :openai, id: "m", base_url: "http://lane/v1"} =
             ReqLLMChat.model_term("openai:m", %{base_url: "http://lane/v1"})
  end

  test "generate_opts/2 threads api_key and tools" do
    opts =
      ReqLLMChat.generate_opts(
        [
          ReqLLM.Tool.new!(
            name: "t",
            description: "",
            parameter_schema: %{},
            callback: fn _ -> {:error, :unused} end
          )
        ],
        %{api_key: "vk-child"}
      )

    assert Keyword.get(opts, :api_key) == "vk-child"
    assert [%ReqLLM.Tool{}] = Keyword.get(opts, :tools)
  end

  test "to_neutral_response/1 converts ReqLLM.Response to the neutral wire shape" do
    tc = ReqLLM.ToolCall.new("tc1", "my_tool", Jason.encode!(%{"x" => 1}))
    msg = %ReqLLM.Message{role: :assistant, content: [], tool_calls: [tc]}

    resp = %ReqLLM.Response{
      id: "resp1",
      model: "openai:test",
      context: ReqLLM.Context.new([]),
      message: msg,
      finish_reason: :tool_calls,
      usage: %{input_tokens: 10, output_tokens: 5}
    }

    neutral = ReqLLMChat.to_neutral_response(resp)

    assert %{
             "choices" => [
               %{
                 "message" => %{
                   "role" => "assistant",
                   "tool_calls" => [
                     %{
                       "id" => "tc1",
                       "type" => "function",
                       "function" => %{"name" => "my_tool"}
                     }
                   ]
                 },
                 "finish_reason" => "tool_calls"
               }
             ],
             "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
           } = neutral
  end
end
