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
      decoded = Jason.decode!(body)
      assert decoded["harnessName"] == "ba"
      assert decoded["executionRoleArn"] =~ "arn:aws:iam"
      assert decoded["systemPrompt"] == [%{"text" => "be helpful"}]
      assert [_ | _] = decoded["tools"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        ~s({"harnessArn":"arn:aws:bedrock-agentcore:us-east-1:1:harness/ba"})
      )
    end)

    spec = %{
      name: "ba",
      execution_role_arn: "arn:aws:iam::123456789012:role/AgentCoreRole",
      system_prompt: "be helpful",
      tools: [
        %{
          "type" => "inline_function",
          "name" => "echo",
          "config" => %{
            "inlineFunction" => %{"description" => "echo", "inputSchema" => %{"type" => "object"}}
          }
        }
      ],
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

  test "invoke_harness posts to /harnesses/invoke with harnessArn in query string and session-id header",
       %{bypass: bypass, client: client} do
    payload = ~s({"messageStop":{"stopReason":"end_turn"}})
    headers = <<>>
    prelude = <<12 + byte_size(headers) + byte_size(payload) + 4::32, byte_size(headers)::32>>
    frame = prelude <> <<:erlang.crc32(prelude)::32>> <> headers <> payload
    frame = frame <> <<:erlang.crc32(frame)::32>>

    test_arn = "arn:aws:bedrock-agentcore:us-east-1:123456789012:harness/ba"
    test_sid = "test-session-id-long-enough-to-satisfy-min-length-33"

    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      assert conn.query_string =~ "harnessArn="

      assert {"x-amzn-bedrock-agentcore-runtime-session-id", ^test_sid} =
               Enum.find(conn.req_headers, fn {k, _} ->
                 k == "x-amzn-bedrock-agentcore-runtime-session-id"
               end)

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"messages" => [_ | _]} = Jason.decode!(body)

      conn
      |> Plug.Conn.put_resp_content_type("application/vnd.amazon.eventstream")
      |> Plug.Conn.resp(200, frame)
    end)

    assert {:ok, [%{"messageStop" => %{"stopReason" => "end_turn"}}]} =
             Client.invoke_harness(client, %{
               harness_arn: test_arn,
               runtime_session_id: test_sid,
               messages: [%{"role" => "user", "content" => [%{"text" => "hi"}]}]
             })
  end

  test "list_harnesses returns the decoded harness list (control plane GET /harnesses)", %{
    bypass: bypass,
    client: client
  } do
    Bypass.expect_once(bypass, "GET", "/harnesses", fn conn ->
      assert {"authorization", "AWS4-HMAC-SHA256" <> _} =
               Enum.find(conn.req_headers, fn {k, _} -> k == "authorization" end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        ~s({"harnesses":[{"harnessName":"ba_abc","harnessId":"h9","arn":"arn:aws:bedrock-agentcore:us-east-1:1:harness/ba_abc","status":"READY"}]})
      )
    end)

    assert {:ok, %{"harnesses" => [%{"harnessName" => "ba_abc", "harnessId" => "h9"}]}} =
             Client.list_harnesses(client)
  end

  test "telemetry [:req_managed_agents, :agent_core, :request, :stop] fires with operation/service/method metadata",
       %{bypass: bypass, client: client} do
    test_pid = self()

    :telemetry.attach(
      "test-agentcore-telemetry-#{inspect(self())}",
      [:req_managed_agents, :agent_core, :request, :stop],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:telemetry_stop, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("test-agentcore-telemetry-#{inspect(test_pid)}")
    end)

    Bypass.expect_once(bypass, "GET", "/harnesses/h2", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"harnessId":"h2","status":"READY"}))
    end)

    assert {:ok, _} = Client.get_harness(client, "h2")

    assert_receive {:telemetry_stop, meta}
    assert meta.operation == :get_harness
    assert meta.service == "bedrock-agentcore"
    assert meta.method == :get
  end

  test "POST invoke_harness is NOT retried on transient server errors (counter == 1)", %{
    bypass: bypass,
    client: client
  } do
    counter = :counters.new(1, [])

    Bypass.stub(bypass, "POST", "/harnesses/invoke", fn conn ->
      :counters.add(counter, 1, 1)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(500, ~s({"message":"Internal Server Error"}))
    end)

    assert {:error, {:http_error, 500, _}} =
             Client.invoke_harness(client, %{
               harness_arn: "arn:aws:bedrock-agentcore:us-east-1:123456789012:harness/h1",
               runtime_session_id: "test-session-id-long-enough-to-satisfy-min-33",
               messages: [%{"role" => "user", "content" => [%{"text" => "hi"}]}]
             })

    assert :counters.get(counter, 1) == 1
  end
end
