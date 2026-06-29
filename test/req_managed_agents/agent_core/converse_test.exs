defmodule ReqManagedAgents.AgentCore.ConverseTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.AgentCore.Converse

  describe "inline_function tool specs" do
    test "Jido schema → HarnessTool shape (GA contract)" do
      jido_schema = [topic: [type: :string, required: true, doc: "the subject"]]

      assert Converse.inline_function("query_external_context", "Query KB", jido_schema) == %{
               "type" => "inline_function",
               "name" => "query_external_context",
               "config" => %{
                 "inlineFunction" => %{
                   "description" => "Query KB",
                   "inputSchema" => %{
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

      # The harness does NOT persist the model's streamed assistant response — we must
      # echo the assistant toolUse back alongside the user toolResult (live-verified;
      # sending only the toolResult fails "toolResult exceeds toolUse of previous turn").
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

  # MIM-52 mechanism. `parse/1` builds its tool_uses list by mapping over `order` (one entry
  # appended per contentBlockStart, no dedup), so nothing guarantees unique toolUseIds. A
  # clean parallel-tool turn (A) is fine; duplicates only arise when the event list carries a
  # reused contentBlockIndex (B — a replayed/concatenated stream) or a reused toolUseId (C).
  # B and C characterize the CURRENT (buggy) output; the fix will flip them while A stays green.
  describe "tool-use id uniqueness (MIM-52)" do
    test "A: clean parallel tools (distinct indices + ids) parse to distinct tool_uses" do
      events = [start_block(0, "tu_1", "f"), start_block(1, "tu_2", "g"), tool_stop()]
      assert ids(Converse.parse(events).tool_uses) == ["tu_1", "tu_2"]
    end

    test "B: a reused contentBlockIndex duplicates one tool and drops the other (BUG)" do
      # Same contentBlockIndex 0 twice — what a replayed/concatenated stream looks like.
      events = [start_block(0, "tu_A", "f"), start_block(0, "tu_B", "g"), tool_stop()]
      # map overwrites index 0 (tu_A lost); order double-counts 0 (tu_B duplicated).
      assert ids(Converse.parse(events).tool_uses) == ["tu_B", "tu_B"]
    end

    test "C: the same toolUseId at two distinct indices yields a duplicate (BUG)" do
      events = [start_block(0, "tu_X", "f"), start_block(1, "tu_X", "g"), tool_stop()]
      assert ids(Converse.parse(events).tool_uses) == ["tu_X", "tu_X"]
    end
  end

  defp ids(tool_uses), do: Enum.map(tool_uses, & &1["toolUseId"])
  defp tool_stop, do: %{"messageStop" => %{"stopReason" => "tool_use"}}

  defp start_block(idx, id, name) do
    %{
      "contentBlockStart" => %{
        "contentBlockIndex" => idx,
        "start" => %{"toolUse" => %{"toolUseId" => id, "name" => name}}
      }
    }
  end
end
