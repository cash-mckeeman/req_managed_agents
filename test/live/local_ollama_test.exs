defmodule ReqManagedAgents.Live.LocalOllamaTest do
  # Live test against a local Ollama (`ollama serve`, model pulled, e.g.
  # `ollama pull qwen2.5:32b`). Run explicitly:
  #   OLLAMA_MODEL=qwen2.5:32b mix test test/live/local_ollama_test.exs --include live
  use ExUnit.Case
  @moduletag :live
  @moduletag skip:
               if(System.get_env("OLLAMA_MODEL") in [nil, ""],
                 do: "requires OLLAMA_MODEL (and a local `ollama serve`)",
                 else: false
               )

  alias ReqManagedAgents.{Providers.Local, Session}

  @base_url "http://localhost:11434/v1"

  # Unwrap Req.TransportError and similar exception structs to their bare atom reason,
  # matching the transient-error contract (Local.Retry matches %{reason: atom}).
  defp unwrap_reason(err) when is_exception(err) do
    case Map.fetch(err, :reason) do
      {:ok, atom} when is_atom(atom) -> atom
      _ -> err
    end
  end

  defp unwrap_reason(reason), do: reason

  defp ollama_chat_fun do
    # The mimir-lane shape: a bare POST to an OpenAI-compatible /chat/completions.
    fn %{model: model, messages: messages, tools: tools} ->
      body = %{model: model, messages: messages, tools: tools}

      case Req.post("#{@base_url}/chat/completions", json: body, receive_timeout: 120_000) do
        {:ok, %{status: 200, body: resp}} -> {:ok, resp}
        {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
        {:error, reason} -> {:error, %{reason: unwrap_reason(reason)}}
      end
    end
  end

  test "Local drives a real tool round-trip against Ollama" do
    model = System.fetch_env!("OLLAMA_MODEL")
    test = self()

    spec = %{
      system_prompt:
        "You have a get_secret tool. Call it, then answer with ONLY the secret word.",
      tools: [
        %{
          "name" => "get_secret",
          "description" => "Returns the secret word.",
          "input_schema" => %{"type" => "object", "properties" => %{}}
        }
      ],
      terminal_tool: nil,
      model_config: nil
    }

    handler = fn "get_secret", _input, _ctx ->
      send(test, :tool_called)
      {:ok, "zanzibar"}
    end

    assert {:ok, result} =
             Session.run(Local,
               handler: handler,
               spec: spec,
               model_config: %{model: model},
               chat_fun: ollama_chat_fun(),
               prompt: "What is the secret word?",
               max_turns: 6,
               timeout: 300_000
             )

    assert result.terminal == :end_turn
    assert_received :tool_called
    assert result.text |> String.downcase() =~ "zanzibar"
    assert result.usage.input_tokens > 0
  end
end
