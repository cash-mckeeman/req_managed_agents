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
      "inlineFunction" => %{
        "name" => name,
        "description" => description,
        "inputSchema" => %{"json" => custom["input_schema"]}
      }
    }
  end

  @doc """
  Fold a single Converse response's event sequence into `%{stop_reason, tool_uses, text}`.

  **Single response only.** `contentBlockIndex` resets to 0 per response;
  concatenating event lists from multiple invocations would collide on shared
  indices and silently drop tools.
  """
  @spec parse([map()]) :: %{stop_reason: String.t() | nil, tool_uses: [map()], text: String.t()}
  def parse(events) do
    init = %{stop_reason: nil, tool_uses: %{}, text: "", order: []}

    state = Enum.reduce(events, init, &reduce_event/2)

    tool_uses =
      state.order
      |> Enum.reverse()
      |> Enum.map(fn idx ->
        %{"toolUseId" => id, "name" => name, "input_acc" => acc} = state.tool_uses[idx]
        %{"toolUseId" => id, "name" => name, "input" => decode_input(acc)}
      end)

    %{stop_reason: state.stop_reason, tool_uses: tool_uses, text: state.text}
  end

  defp reduce_event(
         %{"contentBlockStart" => %{"contentBlockIndex" => i, "start" => %{"toolUse" => tu}}},
         s
       ) do
    entry = %{"toolUseId" => tu["toolUseId"], "name" => tu["name"], "input_acc" => ""}
    %{s | tool_uses: Map.put(s.tool_uses, i, entry), order: [i | s.order]}
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
    update_in(s.tool_uses[i]["input_acc"], &((&1 || "") <> frag))
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
  Assemble the two messages required by the strict Harness resume contract.

  `results` must contain one entry per `tool_uses` entry (same length, each
  entry supplying the `tool_use_id` returned by that call). A length mismatch
  produces a structurally invalid Converse request — Converse requires exactly
  one `toolResult` per `toolUse`.
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
