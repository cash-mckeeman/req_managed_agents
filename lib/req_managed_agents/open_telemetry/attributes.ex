defmodule ReqManagedAgents.OpenTelemetry.Attributes do
  @moduledoc """
  Pure mappers: RMA `:telemetry` metadata -> binary-keyed OTel GenAI (`gen_ai.*`)
  attribute maps. No OTel SDK required. Privacy: scalar metadata + usage + tool
  name only — never message content or tool input/result payloads.
  """
  alias ReqManagedAgents.OpenTelemetry.SemConv

  @spec invoke_agent(map()) :: map()
  def invoke_agent(meta) do
    base(meta) |> Map.put("gen_ai.operation.name", "invoke_agent")
  end

  @spec chat(map()) :: map()
  def chat(meta) do
    base(meta)
    |> Map.put("gen_ai.operation.name", "chat")
    |> put_usage(meta[:usage] || meta["usage"])
  end

  @spec tool(map()) :: map()
  def tool(meta) do
    base(meta)
    |> Map.put("gen_ai.operation.name", "execute_tool")
    |> maybe_put("gen_ai.tool.name", meta[:tool] || meta["tool"])
    |> maybe_error(meta[:is_error] || meta["is_error"])
  end

  @spec terminal(map()) :: map()
  def terminal(meta) do
    base(meta)
    |> maybe_put(
      "gen_ai.response.finish_reasons",
      case meta[:terminal] || meta["terminal"] do
        nil -> nil
        atom -> [SemConv.finish_reason(atom)]
      end
    )
  end

  # session_id -> gen_ai.conversation.id; always set provider.
  defp base(meta) do
    %{"gen_ai.provider.name" => SemConv.provider_name()}
    |> maybe_put("gen_ai.conversation.id", meta[:session_id] || meta["session_id"])
  end

  defp put_usage(attrs, %{} = usage) do
    attrs
    |> maybe_put(
      "gen_ai.usage.input_tokens",
      Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens")
    )
    |> maybe_put(
      "gen_ai.usage.output_tokens",
      Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens")
    )
  end

  defp put_usage(attrs, _), do: attrs

  defp maybe_error(attrs, true), do: Map.put(attrs, "error.type", "tool_error")
  defp maybe_error(attrs, _), do: attrs

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)
end
