defmodule ReqManagedAgents.Providers.Local.ReqLLMChatWireTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Providers.Local
  alias ReqManagedAgents.{Session, SessionResult, Usage}

  for {name, model, base_path, request_path} <- [
        {"Anthropic catalog ID", "anthropic:claude-haiku-4-5", "/v1", "/v1/chat/completions"},
        {"OpenAI catalog ID", "openai:gpt-5", "/v1", "/v1/chat/completions"},
        {"bare reasoning model", "gpt-5", "/v1", "/v1/chat/completions"},
        {"unknown catalog prefix", "unregistered-local-provider:family:model", "/v1",
         "/v1/chat/completions"},
        {"trailing slash", "local-model", "/v1/", "/v1/chat/completions"},
        {"nested base path", "local-model", "/tenant/v1/", "/tenant/v1/chat/completions"},
        {"root base", "local-model", "", "/chat/completions"}
      ] do
    test "default transport preserves #{name} on the declared wire" do
      bypass = Bypass.open()
      test = self()
      model = unquote(model)

      Bypass.expect_once(bypass, fn conn ->
        {body, conn} = capture_request(conn, test)
        Req.Test.json(conn, response(body["model"], "done"))
      end)

      result = run_local(bypass, unquote(base_path), model)

      assert_received {:request, "POST", path, ["Bearer granted-key"], body}
      assert path == unquote(request_path)
      assert body["model"] == model

      assert [%{"role" => "system", "content" => "sys"}, %{"role" => "user", "content" => "hi"}] =
               body["messages"]

      assert {:ok,
              %SessionResult{
                terminal: :end_turn,
                text: "done",
                usage: %Usage{input_tokens: 7, output_tokens: 3}
              }} = result
    end
  end

  test "default transport completes a tool round trip and accumulates real response usage" do
    bypass = Bypass.open()
    test = self()
    model = "anthropic:claude-haiku-4-5"

    Bypass.expect(bypass, fn conn ->
      {body, conn} = capture_request(conn, test)

      reply =
        if Enum.any?(body["messages"], &(&1["role"] == "tool")) do
          response(body["model"], "after lookup")
          |> Map.put("usage", %{
            "prompt_tokens" => 11,
            "completion_tokens" => 5,
            "total_tokens" => 16
          })
        else
          response(body["model"], nil)
          |> put_in(["choices", Access.at(0), "finish_reason"], "tool_calls")
          |> put_in(["choices", Access.at(0), "message", "tool_calls"], [
            %{
              "id" => "call-1",
              "type" => "function",
              "function" => %{"name" => "lookup", "arguments" => ~s({"q":1})}
            }
          ])
        end

      Req.Test.json(conn, reply)
    end)

    handler = fn "lookup", %{"q" => 1}, _context ->
      send(test, :lookup_called)
      {:ok, "found"}
    end

    tool = %{
      "name" => "lookup",
      "description" => "Look up a value",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"q" => %{"type" => "integer"}},
        "required" => ["q"]
      }
    }

    result =
      run_local(bypass, "/v1", model,
        handler: handler,
        spec: %{system_prompt: "sys", tools: [tool]}
      )

    assert_received {:request, "POST", "/v1/chat/completions", ["Bearer granted-key"], first}
    assert first["model"] == model
    assert [%{"function" => %{"name" => "lookup", "parameters" => schema}}] = first["tools"]
    assert schema["properties"] == %{"q" => %{"type" => "integer"}}
    assert_received :lookup_called
    assert_received {:request, "POST", "/v1/chat/completions", ["Bearer granted-key"], second}
    assert second["model"] == model

    assert [
             %{"role" => "system", "content" => "sys"},
             %{"role" => "user", "content" => "hi"},
             %{"role" => "assistant", "tool_calls" => [%{"id" => "call-1"}]},
             %{"role" => "tool", "tool_call_id" => "call-1", "content" => "found"}
           ] = second["messages"]

    assert {:ok,
            %SessionResult{
              terminal: :end_turn,
              text: "after lookup",
              usage: %Usage{input_tokens: 18, output_tokens: 8}
            }} = result

    refute_received {:request, _, _, _, _}
  end

  defp run_local(bypass, base_path, model, opts \\ []) do
    Session.run(
      Local,
      Keyword.merge(
        [
          prompt: "hi",
          spec: %{system_prompt: "sys"},
          model_config: %{
            model: model,
            api_key: "granted-key",
            base_url: "http://localhost:#{bypass.port}#{base_path}"
          },
          handler: fn _, _, _ -> {:ok, ""} end,
          max_turns: 3,
          max_chat_retries: 0,
          timeout: 10_000
        ],
        opts
      )
    )
  end

  defp capture_request(conn, test) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    body = Jason.decode!(raw)

    send(
      test,
      {:request, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"),
       body}
    )

    {body, conn}
  end

  defp response(model, text) do
    %{
      "id" => "chatcmpl-test",
      "object" => "chat.completion",
      "created" => 1,
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => text},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 3, "total_tokens" => 10}
    }
  end
end
