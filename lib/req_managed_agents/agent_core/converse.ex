defmodule ReqManagedAgents.AgentCore.Converse do
  @moduledoc """
  The `:agentcore_harness` wire profile: the Bedrock Converse envelope.

  - `inline_function/3` maps a Jido action (name + description + NimbleOptions
    schema) to a Harness `inlineFunction` (client-side / return-of-control) tool.
  - `parse/1` folds a Converse event sequence into `%{stop_reason, tool_uses, text}`,
    accumulating streamed `toolUse.input` fragments and assistant text deltas.
  - `resume_messages/2` assembles the STRICT resume contract: the next
    `InvokeHarness` MUST carry both the assistant `toolUse` message AND the user
    `toolResult` message, because Harness does not persist the partial inline-tool
    turn. Callers never hand-assemble this.

  Reuses `ReqManagedAgents.ToolSchema`'s JSON-Schema builder for the input schema.
  """
  alias ReqManagedAgents.ToolSchema

  @spec inline_function(String.t(), String.t(), keyword()) :: map()
  def inline_function(name, description, jido_schema) do
    custom = ToolSchema.to_custom_tool(name, description, jido_schema)

    %{
      "type" => "inline_function",
      "name" => name,
      "config" => %{
        "inlineFunction" => %{
          "description" => description,
          "inputSchema" => custom["input_schema"]
        }
      }
    }
  end

  @doc """
  Fold a Converse response's event sequence into `%{stop_reason, tool_uses, text}`.

  Tool blocks are accumulated keyed by **`toolUseId`** — the source of truth, since
  Claude mints a fresh id per real tool call — and emitted in first-seen order.
  Input `toolUse` deltas route to whichever block is *active* at their
  `contentBlockIndex` (tracked per index).

  Keying by id rather than `contentBlockIndex` makes parsing robust to a stream that
  **reuses an index** across two distinct ids (MIM-52: the live Arm-3 vector emitted
  `[{0, A}, {0, B}, {1, C}]` — index 0 reused). An index-keyed fold dropped one tool
  and duplicated the other, producing a duplicate-`toolUseId` resume that Bedrock
  rejected; keying by id recovers both. A genuinely-reused id collapses to one block.
  """
  @spec parse([map()]) :: %{stop_reason: String.t() | nil, tool_uses: [map()], text: String.t()}
  def parse(events) do
    init = %{stop_reason: nil, blocks: %{}, active: %{}, order: [], text: ""}

    state = Enum.reduce(events, init, &reduce_event/2)

    tool_uses =
      state.order
      |> Enum.reverse()
      |> Enum.map(fn id ->
        %{"name" => name, "input_acc" => acc} = state.blocks[id]
        %{"toolUseId" => id, "name" => name, "input" => decode_input(acc)}
      end)

    %{stop_reason: state.stop_reason, tool_uses: tool_uses, text: state.text}
  end

  # A toolUse contentBlockStart opens (or re-opens) a block keyed by its toolUseId and
  # marks that id active at this contentBlockIndex, so subsequent input deltas at the
  # same index route to it. A reused id keeps its first-seen position in `order`.
  defp reduce_event(
         %{"contentBlockStart" => %{"contentBlockIndex" => i, "start" => %{"toolUse" => tu}}},
         s
       ) do
    id = tu["toolUseId"]
    entry = %{"name" => tu["name"], "input_acc" => ""}

    %{
      s
      | blocks: Map.put(s.blocks, id, entry),
        active: Map.put(s.active, i, id),
        order: if(id in s.order, do: s.order, else: [id | s.order])
    }
  end

  defp reduce_event(
         %{
           "contentBlockDelta" => %{
             "contentBlockIndex" => i,
             "delta" => %{"toolUse" => %{"input" => frag}}
           }
         },
         s
       ) do
    case s.active[i] do
      nil -> s
      id -> update_in(s.blocks[id]["input_acc"], &(&1 <> frag))
    end
  end

  defp reduce_event(%{"contentBlockDelta" => %{"delta" => %{"text" => t}}}, s),
    do: %{s | text: s.text <> t}

  defp reduce_event(%{"messageStop" => %{"stopReason" => reason}}, s),
    do: %{s | stop_reason: reason}

  defp reduce_event(_other, s), do: s

  defp decode_input(""), do: %{}

  defp decode_input(acc) do
    case Jason.decode(acc) do
      {:ok, map} -> map
      # Bad JSON (shouldn't happen in a well-formed stream) is treated as empty input.
      {:error, _} -> %{}
    end
  end

  @type tool_result :: %{tool_use_id: String.t(), text: String.t(), is_error: boolean()}

  @doc """
  Assemble the two messages for the next `InvokeHarness` resume turn: the assistant
  `toolUse` blocks AND the user `toolResult`s.

  The harness does NOT persist the model's streamed assistant response into the
  session — sending only the `toolResult` makes Bedrock reject the turn with
  "the number of toolResult blocks ... exceeds the number of toolUse blocks of
  previous turn" (live-verified). So we echo the assistant `toolUse` back.

  `results` must contain one entry per `tool_uses` entry (same length, each
  supplying the `tool_use_id` returned by that call). Bedrock rejects a turn whose
  assistant message carries duplicate `toolUseId`s ("duplicate Ids at
  messages.N.content"); `parse/1` guarantees unique ids by keying tool blocks on
  `toolUseId`, so a well-formed `tool_uses` never trips this (MIM-52).
  """
  @spec resume_messages([map()], [tool_result()]) :: [map()]
  def resume_messages(tool_uses, results) do
    assistant = %{
      "role" => "assistant",
      "content" => Enum.map(tool_uses, fn tu -> %{"toolUse" => tu} end)
    }

    user = %{
      "role" => "user",
      "content" =>
        Enum.map(results, fn r ->
          %{
            "toolResult" => %{
              "toolUseId" => r.tool_use_id,
              "content" => [%{"text" => r.text}],
              "status" => if(r.is_error, do: "error", else: "success")
            }
          }
        end)
    }

    [assistant, user]
  end
end
