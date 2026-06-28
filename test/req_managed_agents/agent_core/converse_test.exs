defmodule ReqManagedAgents.AgentCore.ConverseTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.AgentCore.Converse

  describe "inline_function tool specs" do
    test "Jido schema → inlineFunction tool spec" do
      jido_schema = [topic: [type: :string, required: true, doc: "the subject"]]

      assert Converse.inline_function("query_external_context", "Query KB", jido_schema) == %{
               "inlineFunction" => %{
                 "name" => "query_external_context",
                 "description" => "Query KB",
                 "inputSchema" => %{
                   "json" => %{
                     "type" => "object",
                     "properties" => %{
                       "topic" => %{"type" => "string", "description" => "the subject"}
                     },
                     "required" => ["topic"]
                   }
                 }
               }
             }
    end
  end

  describe "parsing a Converse event sequence" do
    test "accumulates a toolUse block and terminates on stopReason tool_use" do
      events = [
        %{"messageStart" => %{"role" => "assistant"}},
        %{
          "contentBlockStart" => %{
            "contentBlockIndex" => 0,
            "start" => %{"toolUse" => %{"toolUseId" => "tu_1", "name" => "echo"}}
          }
        },
        %{
          "contentBlockDelta" => %{
            "contentBlockIndex" => 0,
            "delta" => %{"toolUse" => %{"input" => "{\"text\":\"hi"}}
          }
        },
        %{
          "contentBlockDelta" => %{
            "contentBlockIndex" => 0,
            "delta" => %{"toolUse" => %{"input" => "\"}"}}
          }
        },
        %{"contentBlockStop" => %{"contentBlockIndex" => 0}},
        %{"messageStop" => %{"stopReason" => "tool_use"}}
      ]

      assert %{stop_reason: "tool_use", tool_uses: [tu], text: text} = Converse.parse(events)
      assert tu == %{"toolUseId" => "tu_1", "name" => "echo", "input" => %{"text" => "hi"}}
      assert text == ""
    end

    test "accumulates assistant text and terminates on a normal stop" do
      events = [
        %{"messageStart" => %{"role" => "assistant"}},
        %{"contentBlockDelta" => %{"contentBlockIndex" => 0, "delta" => %{"text" => "all "}}},
        %{"contentBlockDelta" => %{"contentBlockIndex" => 0, "delta" => %{"text" => "done."}}},
        %{"messageStop" => %{"stopReason" => "end_turn"}}
      ]

      assert %{stop_reason: "end_turn", tool_uses: [], text: "all done."} = Converse.parse(events)
    end
  end

  describe "strict resume contract" do
    test "assembles assistant toolUse + user toolResult messages for the next invoke" do
      tu = %{"toolUseId" => "tu_1", "name" => "echo", "input" => %{"text" => "hi"}}
      result = %{tool_use_id: "tu_1", text: "echoed: hi", is_error: false}

      assert Converse.resume_messages([tu], [result]) == [
               %{
                 "role" => "assistant",
                 "content" => [
                   %{
                     "toolUse" => %{
                       "toolUseId" => "tu_1",
                       "name" => "echo",
                       "input" => %{"text" => "hi"}
                     }
                   }
                 ]
               },
               %{
                 "role" => "user",
                 "content" => [
                   %{
                     "toolResult" => %{
                       "toolUseId" => "tu_1",
                       "content" => [%{"text" => "echoed: hi"}],
                       "status" => "success"
                     }
                   }
                 ]
               }
             ]
    end

    test "an errored tool result carries status error" do
      tu = %{"toolUseId" => "tu_2", "name" => "boom", "input" => %{}}
      result = %{tool_use_id: "tu_2", text: "kaboom", is_error: true}
      [_assistant, user] = Converse.resume_messages([tu], [result])
      assert get_in(user, ["content", Access.at(0), "toolResult", "status"]) == "error"
    end
  end
end
