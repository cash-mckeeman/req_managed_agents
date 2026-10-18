defmodule ReqManagedAgents.Test.ExecutionUsageFixture do
  @moduledoc false

  alias ReqManagedAgents.Providers.{BedrockAgentCore, ClaudeManagedAgents, Local}
  alias ReqManagedAgents.Providers.Local.ReqLLMChat
  alias ReqManagedAgents.{Session, Usage}

  @spec samples() :: %{String.t() => Usage.t()}
  def samples do
    known = %{
      "prompt_tokens" => 12,
      "completion_tokens" => 4,
      "prompt_tokens_details" => %{"cached_tokens" => 3, "cache_write_tokens" => 2}
    }

    zero = %{
      "prompt_tokens" => 0,
      "completion_tokens" => 0,
      "prompt_tokens_details" => %{"cached_tokens" => 0, "cache_write_tokens" => 0}
    }

    cma = %{
      "input_tokens" => 12,
      "output_tokens" => 4,
      "cache_read_input_tokens" => 3,
      "cache_creation_input_tokens" => 2
    }

    bedrock = %{
      "inputTokens" => 12,
      "outputTokens" => 4,
      "cacheReadInputTokens" => 3,
      "cacheWriteInputTokens" => 2
    }

    {:ok, decoded} = ReqLLM.Response.decode_response(openai_response(zero), "openai:gpt-5")
    neutral = ReqLLMChat.to_neutral_response(decoded)

    %{
      "local-inclusive" => run([known]),
      "local-uncached" => run([Map.put(known, "input_token_basis", "uncached")]),
      "local-zero" => run([zero]),
      "local-missing" => run([Map.delete(known, "prompt_tokens_details")]),
      "local-mixed" => run([known, nil]),
      "req-llm-ambiguous-zero" => run_neutral(fn _ -> {:ok, neutral} end),
      "cma-request" =>
        ClaudeManagedAgents.normalize([
          %{"id" => "model-request", "type" => "span.model_request_end", "model_usage" => cma}
        ]).usage,
      "agentcore-turn" =>
        BedrockAgentCore.normalize([
          %{"metadata" => %{"usage" => bedrock}},
          %{"messageStop" => %{"stopReason" => "end_turn"}}
        ]).usage
    }
  end

  defp run(reports) do
    run_neutral(fn request ->
      followup? = Enum.any?(request.messages, &(&1["role"] == "tool"))
      usage = if followup?, do: List.last(reports), else: hd(reports)
      {:ok, response(usage, length(reports) > 1 and not followup?)}
    end)
  end

  defp run_neutral(chat) do
    {:ok, result} =
      Session.run(Local,
        chat_fun: chat,
        prompt: "go",
        model_config: %{model: "test-model"},
        handler: fn _, _, _ -> {:ok, "done"} end
      )

    result.usage
  end

  defp response(usage, tool?) do
    message =
      if tool?,
        do: %{
          "content" => nil,
          "tool_calls" => [
            %{"id" => "tool-1", "function" => %{"name" => "echo", "arguments" => "{}"}}
          ]
        },
        else: %{"content" => "done"}

    %{
      "choices" => [
        %{"message" => message, "finish_reason" => if(tool?, do: "tool_calls", else: "stop")}
      ],
      "usage" => usage
    }
  end

  defp openai_response(usage) do
    response(usage, false)
    |> Map.merge(%{
      "id" => "response",
      "model" => "gpt-5",
      "object" => "chat.completion",
      "created" => 1
    })
    |> put_in(["usage", "total_tokens"], 0)
  end
end
