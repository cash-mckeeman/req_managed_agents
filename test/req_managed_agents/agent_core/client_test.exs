defmodule ReqManagedAgents.AgentCore.ClientTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.AgentCore.Client

  @creds %{
    access_key_id: "AKID",
    secret_access_key: "secret",
    region: "us-east-1",
    security_token: nil
  }

  setup do
    bypass = Bypass.open()
    client = Client.new(credentials: @creds, base_url: "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass, client: client}
  end

  test "create_harness signs the request and returns the harnessArn", %{
    bypass: bypass,
    client: client
  } do
    Bypass.expect_once(bypass, "POST", "/harnesses", fn conn ->
      assert {"authorization", "AWS4-HMAC-SHA256" <> _} =
               Enum.find(conn.req_headers, fn {k, _} -> k == "authorization" end)

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"name" => "ba", "instruction" => _, "tools" => [_ | _]} = Jason.decode!(body)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        ~s({"harnessArn":"arn:aws:bedrock-agentcore:us-east-1:1:harness/ba"})
      )
    end)

    spec = %{
      name: "ba",
      system_prompt: "be helpful",
      tools: [%{"inlineFunction" => %{"name" => "echo"}}],
      model: %{"bedrockModelConfig" => %{"modelId" => "anthropic.claude-sonnet-4"}}
    }

    assert {:ok, %{"harnessArn" => "arn:aws:bedrock-agentcore:us-east-1:1:harness/ba"}} =
             Client.create_harness(client, spec)
  end

  test "create_api_key_credential_provider returns the token-vault apiKeyArn", %{
    bypass: bypass,
    client: client
  } do
    Bypass.expect_once(bypass, "POST", "/credential-providers/api-key", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        ~s({"credentialProviderArn":"arn:aws:bedrock-agentcore:us-east-1:1:token-vault/default/apikeycredentialprovider/mimir"})
      )
    end)

    assert {:ok, %{"credentialProviderArn" => arn}} =
             Client.create_api_key_credential_provider(client, %{name: "mimir", api_key: "vk-123"})

    assert arn =~ "token-vault/default/apikeycredentialprovider/"
  end

  test "invoke_harness posts to the runtime invocations path and decodes the event stream", %{
    bypass: bypass,
    client: client
  } do
    payload = ~s({"messageStop":{"stopReason":"end_turn"}})
    headers = <<>>
    prelude = <<12 + byte_size(headers) + byte_size(payload) + 4::32, byte_size(headers)::32>>
    frame = prelude <> <<:erlang.crc32(prelude)::32>> <> headers <> payload
    frame = frame <> <<:erlang.crc32(frame)::32>>

    Bypass.expect_once(bypass, "POST", "/harnesses/ba/invocations", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/vnd.amazon.eventstream")
      |> Plug.Conn.resp(200, frame)
    end)

    assert {:ok, [%{"messageStop" => %{"stopReason" => "end_turn"}}]} =
             Client.invoke_harness(client, %{
               harness_id: "ba",
               runtime_session_id: "s1",
               messages: [%{"role" => "user", "content" => [%{"text" => "hi"}]}]
             })
  end

  test "POST invoke_harness is NOT retried on transient server errors (counter == 1)", %{
    bypass: bypass,
    client: client
  } do
    counter = :counters.new(1, [])

    Bypass.stub(bypass, "POST", "/harnesses/h1/invocations", fn conn ->
      :counters.add(counter, 1, 1)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(500, ~s({"message":"Internal Server Error"}))
    end)

    assert {:error, {:http_error, 500, _}} =
             Client.invoke_harness(client, %{
               harness_id: "h1",
               runtime_session_id: "s1",
               messages: [%{"role" => "user", "content" => [%{"text" => "hi"}]}]
             })

    assert :counters.get(counter, 1) == 1
  end
end
