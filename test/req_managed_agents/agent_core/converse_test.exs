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

  # `parse/1` accumulates tool blocks keyed by `toolUseId` (the source of
  # truth — Claude mints a fresh id per real call) and routes input deltas via a
  # per-`contentBlockIndex` "active block" pointer. This survives a stream that reuses
  # contentBlockIndex (B — a replayed/concatenated stream: both distinct ids are
  # recovered, in first-seen order) and dedupes a genuinely-reused id (C). A clean
  # parallel-tool turn (A) is unchanged. Live-confirmed mechanism: the Arm-3 vector
  # emitted [{0, A}, {0, B}, {1, C}] — index 0 reused across two DISTINCT ids.
  describe "tool-use id uniqueness" do
    test "A: clean parallel tools (distinct indices + ids) parse to distinct tool_uses" do
      events = [start_block(0, "tu_1", "f"), start_block(1, "tu_2", "g"), tool_stop()]
      assert ids(Converse.parse(events).tool_uses) == ["tu_1", "tu_2"]
    end

    test "B: a reused contentBlockIndex recovers BOTH distinct tools, in first-seen order" do
      # Same contentBlockIndex 0 twice with distinct ids — what a replayed/concatenated
      # stream looks like. Keying by id (not index) keeps both; neither is dropped.
      events = [start_block(0, "tu_A", "f"), start_block(0, "tu_B", "g"), tool_stop()]
      assert ids(Converse.parse(events).tool_uses) == ["tu_A", "tu_B"]
    end

    test "C: the same toolUseId at two indices dedupes to a single tool" do
      events = [start_block(0, "tu_X", "f"), start_block(1, "tu_X", "g"), tool_stop()]
      assert ids(Converse.parse(events).tool_uses) == ["tu_X"]
    end

    test "input deltas route to the active block at their index, even when index is reused" do
      # tu_A opens at index 0, gets its input; then index 0 is reused for tu_B, whose
      # input must NOT bleed into tu_A. Distinct ids, distinct inputs preserved.
      events = [
        start_block(0, "tu_A", "f"),
        delta(0, "{\"a\":1}"),
        start_block(0, "tu_B", "g"),
        delta(0, "{\"b\":2}"),
        tool_stop()
      ]

      assert [tu_a, tu_b] = Converse.parse(events).tool_uses
      assert tu_a == %{"toolUseId" => "tu_A", "name" => "f", "input" => %{"a" => 1}}
      assert tu_b == %{"toolUseId" => "tu_B", "name" => "g", "input" => %{"b" => 2}}
    end
  end

  test "parse/1 extracts metadata.usage" do
    events = [
      %{"messageStop" => %{"stopReason" => "end_turn"}},
      %{
        "metadata" => %{
          "usage" => %{"inputTokens" => 12, "outputTokens" => 7, "totalTokens" => 19}
        }
      }
    ]

    assert %{usage: %{"inputTokens" => 12, "outputTokens" => 7}} = Converse.parse(events)
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

  defp delta(idx, frag) do
    %{
      "contentBlockDelta" => %{
        "contentBlockIndex" => idx,
        "delta" => %{"toolUse" => %{"input" => frag}}
      }
    }
  end
end
