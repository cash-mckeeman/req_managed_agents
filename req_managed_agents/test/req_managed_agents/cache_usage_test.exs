defmodule ReqManagedAgents.CacheUsageTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Providers.{BedrockAgentCore, ClaudeManagedAgents, Local}
  alias ReqManagedAgents.Providers.Local.ReqLLMChat
  alias ReqManagedAgents.Session

  for provider <- [ClaudeManagedAgents, BedrockAgentCore, Local] do
    @provider provider
    test "#{inspect(provider)} preserves native counts and basis" do
      raw = native_usage(@provider)
      usage = normalize(@provider, raw)
      assert usage.input_tokens == 12
      assert usage.output_tokens == 4
      assert usage.cache_read_input_tokens == 3
      assert usage.cache_creation_input_tokens == 2
      assert usage.input_token_basis == if(@provider == Local, do: :inclusive, else: :uncached)
      assert usage.complete?
      assert usage.raw == [raw]
    end

    test "#{inspect(provider)} distinguishes zero from missing and invalid cache fields" do
      for field <- [:read, :creation], value <- [nil, -1, 1.5, "3", :missing, 0] do
        raw = change_cache(@provider, native_usage(@provider), field, value)
        usage = normalize(@provider, raw)
        key = if field == :read, do: :cache_read_input_tokens, else: :cache_creation_input_tokens
        assert Map.fetch!(usage, key) == if(value == 0, do: 0, else: nil)
        assert usage.complete? == (value == 0)
        assert usage.raw == [raw]
      end
    end
  end

  test "CMA sums request ends without counting cumulative snapshots" do
    raw = native_usage(ClaudeManagedAgents)

    snapshot = %{
      "type" => "session.usage",
      "usage" => %{
        "input_tokens" => 900,
        "output_tokens" => 700,
        "cache_read_input_tokens" => 800
      }
    }

    events = [snapshot, cma_event("a", raw), cma_event("b", raw)]
    usage = ClaudeManagedAgents.normalize(events).usage
    assert usage.input_tokens == 24
    assert usage.output_tokens == 8
    assert usage.cache_read_input_tokens == 6
    assert usage.cache_creation_input_tokens == 4
    assert usage.raw == [raw, raw]
    assert usage.complete?
  end

  test "CMA missing request usage poisons coverage and retains known subtotals" do
    known = cma_event("a", native_usage(ClaudeManagedAgents))
    missing = %{"id" => "b", "type" => "span.model_request_end"}

    for events <- [[known, missing], [missing, known]] do
      usage = ClaudeManagedAgents.normalize(events).usage
      assert usage.input_tokens == 12
      assert usage.output_tokens == 4
      assert usage.cache_read_input_tokens == nil
      assert usage.cache_creation_input_tokens == nil
      refute usage.complete?
    end

    assert ClaudeManagedAgents.normalize([missing]).usage == nil
  end

  test "CMA keeps model_usage precedence over its legacy usage fallback" do
    raw = native_usage(ClaudeManagedAgents)
    assert normalize(ClaudeManagedAgents, raw).cache_creation_input_tokens == 2
    event = cma_event("legacy", raw) |> Map.delete("model_usage") |> Map.put("usage", raw)
    assert ClaudeManagedAgents.normalize([event]).usage.cache_read_input_tokens == 3
    event = cma_event("preferred", raw) |> Map.put("usage", %{"input_tokens" => 999})
    assert ClaudeManagedAgents.normalize([event]).usage.input_tokens == 12
  end

  test "Local retains observed output and cache counts when input is absent" do
    for raw <- [
          Map.delete(native_usage(Local), "prompt_tokens"),
          Map.put(native_usage(Local), "prompt_tokens", nil)
        ] do
      assert {:ok, result} = run_local(fn _ -> {:ok, response(raw, false)} end)
      assert result.usage.input_tokens == 0
      assert result.usage.output_tokens == 4
      assert result.usage.cache_read_input_tokens == 3
      assert result.usage.cache_creation_input_tokens == 2
      assert result.usage.input_token_basis == :inclusive
      assert result.usage.raw == [raw]
      refute result.usage.complete?
    end
  end

  test "Local rejects invalid supplied input counts instead of certifying partial usage" do
    for input <- [-1, 1.5, "12"] do
      raw = Map.put(native_usage(Local), "prompt_tokens", input)
      assert normalize(Local, raw) == nil
      assert {:ok, result} = run_local(fn _ -> {:ok, response(raw, false)} end)
      assert result.usage.output_tokens == 0
      assert result.usage.cache_read_input_tokens == nil
      assert result.usage.cache_creation_input_tokens == nil
      refute result.usage.complete?
    end
  end

  test "Local parses only the closed basis extension without changing input counts" do
    for {wire, basis} <- [
          {"inclusive", :inclusive},
          {"uncached", :uncached},
          {"unknown", :unknown},
          {"invented", :unknown},
          {nil, :unknown}
        ] do
      raw = Map.put(native_usage(Local), "input_token_basis", wire)
      usage = normalize(Local, raw)
      assert usage.input_tokens == 12
      assert usage.input_token_basis == basis
      assert usage.complete? == (basis != :unknown)
    end
  end

  test "Session folds known and missing Local turns in either order" do
    raw = native_usage(Local)

    for reports <- [[raw, nil], [nil, raw]] do
      script = start_supervised!({Agent, fn -> reports end}, id: make_ref())

      chat = fn _request ->
        Agent.get_and_update(script, fn [usage | rest] ->
          {{:ok, response(usage, rest != [])}, rest}
        end)
      end

      assert {:ok, result} = run_local(chat)
      assert result.turns == 2
      assert result.usage.input_tokens == 12
      assert result.usage.output_tokens == 4
      assert result.usage.cache_read_input_tokens == nil
      assert result.usage.cache_creation_input_tokens == nil
      refute result.usage.complete?
    end
  end

  test "Session keeps missing usage unknown before and after measured zero" do
    zero = %{
      "prompt_tokens" => 0,
      "completion_tokens" => 0,
      "prompt_tokens_details" => %{"cached_tokens" => 0, "cache_write_tokens" => 0}
    }

    assert {:ok, measured} = run_local(fn _ -> {:ok, response(zero, false)} end)
    assert measured.usage.input_tokens == 0
    assert measured.usage.output_tokens == 0
    assert measured.usage.cache_read_input_tokens == 0
    assert measured.usage.cache_creation_input_tokens == 0
    assert measured.usage.input_token_basis == :inclusive
    assert measured.usage.complete?

    for reports <- [[nil, zero], [zero, nil]] do
      script = start_supervised!({Agent, fn -> reports end}, id: make_ref())

      chat = fn _request ->
        Agent.get_and_update(script, fn [usage | rest] ->
          {{:ok, response(usage, rest != [])}, rest}
        end)
      end

      assert {:ok, result} = run_local(chat)
      assert result.turns == 2
      assert result.usage.input_tokens == 0
      assert result.usage.output_tokens == 0
      assert result.usage.cache_read_input_tokens == nil
      assert result.usage.cache_creation_input_tokens == nil
      assert result.usage.input_token_basis == :unknown
      assert result.usage.raw == [zero]
      refute result.usage.complete?
    end
  end

  test "Local live requests reset cache counts while one request accumulates them" do
    raw = native_usage(Local)
    chat = fn _ -> {:ok, response(raw, false)} end

    pid =
      start_supervised!(%{
        id: make_ref(),
        start: {Session, :start_link, [Local, local_opts(chat) ++ [notify: self()]]}
      })

    assert_receive {:managed_agents_session, first}, 2_000
    assert first.usage.cache_read_input_tokens == 3
    Session.message(pid, "next")
    assert_receive {:managed_agents_session, second}, 2_000
    assert second.usage.input_tokens == 12
    assert second.usage.cache_read_input_tokens == 3
    assert second.usage.cache_creation_input_tokens == 2
    assert second.usage.complete?
  end

  test "actual ReqLLM decoding retains cache counts without inventing an unexposed input basis" do
    for {model, raw, creation} <- [
          {"openai:gpt-5", openai_response(native_usage(Local)), nil},
          {"anthropic:claude-haiku-4-5", anthropic_response(native_usage(ClaudeManagedAgents)), 2}
        ] do
      assert {:ok, decoded} = ReqLLM.Response.decode_response(raw, model)
      refute Map.has_key?(ReqLLM.Response.usage(decoded), :input_includes_cached)
      neutral = ReqLLMChat.to_neutral_response(decoded)
      assert {:ok, result} = run_local(fn _ -> {:ok, neutral} end)
      usage = result.usage
      assert usage.input_tokens == 12
      assert usage.output_tokens == 4
      assert usage.cache_read_input_tokens == 3
      assert usage.cache_creation_input_tokens == creation
      assert usage.input_token_basis == :unknown
      refute usage.complete?
    end
  end

  test "ReqLLM supplied basis flags are projected without coercing absent facts" do
    for {flag, basis} <- [
          {true, :inclusive},
          {false, :uncached},
          {nil, :unknown},
          {"false", :unknown}
        ] do
      assert {:ok, decoded} =
               ReqLLM.Response.decode_response(
                 anthropic_response(native_usage(ClaudeManagedAgents)),
                 "anthropic:claude-haiku-4-5"
               )

      decoded = %{decoded | usage: Map.put(decoded.usage, :input_includes_cached, flag)}
      neutral = ReqLLMChat.to_neutral_response(decoded)
      assert {:ok, result} = run_local(fn _ -> {:ok, neutral} end)
      assert result.usage.input_token_basis == basis
      assert result.usage.input_tokens == 12
      assert result.usage.cache_read_input_tokens == 3
      assert result.usage.cache_creation_input_tokens == 2
      assert result.usage.complete? == (basis != :unknown)
    end
  end

  test "ReqLLM native missing and zero cache observations remain indistinguishable and unknown" do
    raw = native_usage(Local)

    reports = [
      Map.delete(raw, "prompt_tokens_details"),
      Map.put(raw, "prompt_tokens_details", %{"cached_tokens" => 0, "cache_write_tokens" => 0})
    ]

    decoded =
      Enum.map(reports, fn usage ->
        assert {:ok, decoded} =
                 ReqLLM.Response.decode_response(openai_response(usage), "openai:gpt-5")

        decoded
      end)

    [first, second] =
      Enum.map(
        decoded,
        &Map.take(
          ReqLLM.Response.usage(&1),
          [:cached_tokens, :cache_creation_tokens, :input_includes_cached]
        )
      )

    assert first == second
    assert first.cached_tokens == 0

    for response <- decoded do
      neutral = ReqLLMChat.to_neutral_response(response)
      assert {:ok, result} = run_local(fn _ -> {:ok, neutral} end)
      assert result.usage.cache_read_input_tokens == nil
      assert result.usage.cache_creation_input_tokens == nil
      refute result.usage.complete?
    end
  end

  defp native_usage(ClaudeManagedAgents),
    do: %{
      "input_tokens" => 12,
      "output_tokens" => 4,
      "cache_read_input_tokens" => 3,
      "cache_creation_input_tokens" => 2
    }

  defp native_usage(BedrockAgentCore),
    do: %{
      "inputTokens" => 12,
      "outputTokens" => 4,
      "cacheReadInputTokens" => 3,
      "cacheWriteInputTokens" => 2
    }

  defp native_usage(Local),
    do: %{
      "prompt_tokens" => 12,
      "completion_tokens" => 4,
      "total_tokens" => 16,
      "prompt_tokens_details" => %{"cached_tokens" => 3, "cache_write_tokens" => 2}
    }

  defp change_cache(Local, raw, field, value) do
    key = if field == :read, do: "cached_tokens", else: "cache_write_tokens"
    details = raw["prompt_tokens_details"]
    Map.put(raw, "prompt_tokens_details", change(details, key, value))
  end

  defp change_cache(provider, raw, field, value) do
    key =
      case {provider, field} do
        {ClaudeManagedAgents, :read} -> "cache_read_input_tokens"
        {ClaudeManagedAgents, :creation} -> "cache_creation_input_tokens"
        {BedrockAgentCore, :read} -> "cacheReadInputTokens"
        {BedrockAgentCore, :creation} -> "cacheWriteInputTokens"
      end

    change(raw, key, value)
  end

  defp change(map, key, :missing), do: Map.delete(map, key)
  defp change(map, key, value), do: Map.put(map, key, value)

  defp cma_event(id, usage),
    do: %{"type" => "span.model_request_end", "id" => id, "model_usage" => usage}

  defp normalize(ClaudeManagedAgents, raw),
    do: ClaudeManagedAgents.normalize([cma_event("one", raw)]).usage

  defp normalize(BedrockAgentCore, raw),
    do:
      BedrockAgentCore.normalize([
        %{"metadata" => %{"usage" => raw}},
        %{"messageStop" => %{"stopReason" => "end_turn"}}
      ]).usage

  defp normalize(Local, raw),
    do:
      Local.normalize([
        %{
          "type" => "local.model_response",
          "message" => %{"content" => "done"},
          "finish_reason" => "stop",
          "usage" => raw
        }
      ]).usage

  defp local_opts(chat),
    do: [
      handler: fn _, _, _ -> {:ok, "done"} end,
      chat_fun: chat,
      model_config: %{model: "test-model"},
      prompt: "go"
    ]

  defp run_local(chat), do: Session.run(Local, local_opts(chat))

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

  defp openai_response(usage),
    do:
      response(usage, false)
      |> Map.merge(%{
        "id" => "response",
        "model" => "gpt-5",
        "object" => "chat.completion",
        "created" => 1
      })

  defp anthropic_response(usage),
    do: %{
      "id" => "response",
      "model" => "claude-haiku-4-5",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "text", "text" => "done"}],
      "stop_reason" => "end_turn",
      "usage" => usage
    }
end
