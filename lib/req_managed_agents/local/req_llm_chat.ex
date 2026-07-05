defmodule ReqManagedAgents.Local.ReqLLMChat do
  @moduledoc false
  # The DEFAULT chat_fun for Providers.Local: adapts the neutral OpenAI-shaped wire
  # contract to ReqLLM.generate_text/3. Only this module touches ReqLLM — injected
  # chat_funs never need req_llm present (Local.Deps gates construction).

  alias ReqManagedAgents.Local.Deps

  @spec chat_fun(map()) :: (map() -> {:ok, map()} | {:error, term()})
  def chat_fun(model_config) do
    Deps.ensure!()

    fn %{model: model, messages: messages, tools: tools} ->
      result =
        ReqLLM.generate_text(
          model_term(model, model_config),
          to_context(messages),
          generate_opts(to_tools(tools), model_config)
        )

      case result do
        {:ok, response} -> {:ok, to_neutral_response(response)}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc false
  def model_term(model, %{base_url: base_url}) when is_binary(base_url) do
    case String.split(to_string(model), ":", parts: 2) do
      [provider, id] -> %{provider: String.to_atom(provider), id: id, base_url: base_url}
      [id] -> %{provider: :openai, id: id, base_url: base_url}
    end
  end

  def model_term(model, _model_config), do: model

  @doc false
  def generate_opts(tools, %{api_key: key}) when is_binary(key), do: [tools: tools, api_key: key]
  def generate_opts(tools, _model_config), do: [tools: tools]

  @doc false
  def to_context(messages) do
    messages
    |> Enum.map(&to_req_llm_message/1)
    |> ReqLLM.Context.new()
  end

  defp to_req_llm_message(%{"role" => "system", "content" => c}), do: ReqLLM.Context.system(c)
  defp to_req_llm_message(%{"role" => "user", "content" => c}), do: ReqLLM.Context.user(c)

  defp to_req_llm_message(%{"role" => "assistant", "tool_calls" => [_ | _] = calls} = m) do
    ReqLLM.Context.assistant(m["content"] || "",
      tool_calls:
        Enum.map(calls, fn %{"id" => id, "function" => %{"name" => n, "arguments" => a}} ->
          ReqLLM.ToolCall.new(id, n, a)
        end)
    )
  end

  defp to_req_llm_message(%{"role" => "assistant", "content" => c}),
    do: ReqLLM.Context.assistant(c || "")

  # tool_result/2 is used (no name arg) — the neutral "tool" message carries no name field
  defp to_req_llm_message(%{"role" => "tool", "tool_call_id" => id, "content" => c}),
    do: ReqLLM.Context.tool_result(id, c)

  @doc false
  def to_tools(tools) do
    Enum.map(tools, fn %{"function" => f} ->
      ReqLLM.Tool.new!(
        name: f["name"],
        description: f["description"] || "",
        parameter_schema: f["parameters"] || %{},
        callback: fn _ -> {:error, :unused} end
      )
    end)
  end

  @doc false
  def to_neutral_response(response) do
    tool_calls = Enum.map(ReqLLM.Response.tool_calls(response), &to_neutral_tool_call/1)

    %{
      "choices" => [
        %{
          "message" => assistant_message(ReqLLM.Response.text(response), tool_calls),
          # Response.finish_reason/1 returns an atom; convert to string for neutral wire
          "finish_reason" => finish_reason(response, tool_calls)
        }
      ],
      "usage" => to_neutral_usage(ReqLLM.Response.usage(response))
    }
  end

  defp to_neutral_tool_call(call) do
    %{
      "id" => call.id,
      "type" => "function",
      "function" => %{"name" => call.function.name, "arguments" => call.function.arguments}
    }
  end

  defp assistant_message(text, []), do: %{"role" => "assistant", "content" => text}

  defp assistant_message(text, tool_calls),
    do: %{"role" => "assistant", "content" => text, "tool_calls" => tool_calls}

  # Prefer the response's own finish_reason when available; fall back to inferring from tool_calls
  defp finish_reason(response, tool_calls) do
    case ReqLLM.Response.finish_reason(response) do
      reason when reason in [:stop, :tool_calls, :length, :content_filter, :error, :cancelled, :incomplete, :unknown] ->
        Atom.to_string(reason)

      _ ->
        if tool_calls == [], do: "stop", else: "tool_calls"
    end
  end

  # One shape, matched once — :input_tokens/:output_tokens are the canonical field names
  # in the resolved req_llm usage map (verified against deps/req_llm/lib/req_llm/usage.ex).
  defp to_neutral_usage(%{input_tokens: input, output_tokens: output}),
    do: %{"prompt_tokens" => input, "completion_tokens" => output}

  defp to_neutral_usage(_), do: nil
end
