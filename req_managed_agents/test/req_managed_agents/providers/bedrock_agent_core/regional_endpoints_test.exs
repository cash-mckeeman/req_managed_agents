defmodule ReqManagedAgents.Providers.BedrockAgentCore.RegionalEndpointsTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.AgentCore.Client, as: LegacyClient
  alias ReqManagedAgents.Providers.BedrockAgentCore.Client

  for module <- [Client, LegacyClient],
      {region, invoke_url, control_url} <- [
        {"us-east-1", "https://bedrock-agentcore.us-east-1.amazonaws.com",
         "https://bedrock-agentcore-control.us-east-1.amazonaws.com"},
        {"us-west-2", "https://bedrock-agentcore.us-west-2.amazonaws.com",
         "https://bedrock-agentcore-control.us-west-2.amazonaws.com"},
        {"eu-west-1", "https://bedrock-agentcore.eu-west-1.amazonaws.com",
         "https://bedrock-agentcore-control.eu-west-1.amazonaws.com"}
      ] do
    for {shape, overrides} <- [
          {:defaults, []},
          {:invoke_only, [base_url: "https://invoke.example.test:8443/custom/"]},
          {:control_only, [control_base_url: "https://control.example.test:9443/custom/"]},
          {:both,
           [
             base_url: "https://invoke.example.test:8443/custom/",
             control_base_url: "https://control.example.test:9443/custom/"
           ]}
        ] do
      test "#{inspect(module)} #{region} #{shape} keeps regional endpoints independent" do
        credentials = credentials(unquote(region))
        overrides = unquote(overrides)
        client = unquote(module).new([credentials: credentials] ++ overrides)

        assert client.base_url == Keyword.get(overrides, :base_url, unquote(invoke_url))

        assert client.control_base_url ==
                 Keyword.get(overrides, :control_base_url, unquote(control_url))

        assert client.credentials == credentials
      end
    end

    test "#{inspect(module)} #{region} signs both regional request paths with the credential region" do
      client =
        unquote(module).new(
          credentials: credentials(unquote(region)),
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.host == URI.parse(unquote(control_url)).host
        assert conn.request_path == "/harnesses"
        assert conn.method == "POST"
        assert_signing_region(conn, unquote(region))
        Plug.Conn.resp(conn, 400, "observed control request")
      end)

      assert {:error, {:http_error, 400, "observed control request"}} =
               unquote(module).create_harness(client, %{
                 name: "test-harness",
                 execution_role_arn: "role",
                 system_prompt: "test",
                 model: %{},
                 tools: []
               })

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.host == URI.parse(unquote(invoke_url)).host
        assert conn.request_path == "/harnesses/invoke"
        assert conn.method == "POST"
        assert URI.decode_query(conn.query_string) == %{"harnessArn" => "arn:new"}
        assert_signing_region(conn, unquote(region))
        Plug.Conn.resp(conn, 400, "observed invocation request")
      end)

      assert {:error, {:http_error, 400, "observed invocation request"}} =
               unquote(module).invoke_harness(client, %{
                 harness_arn: "arn:new",
                 runtime_session_id: "test-session-id-long-enough-for-agentcore",
                 messages: []
               })
    end
  end

  defp credentials(region) do
    %{
      access_key_id: "test-access-key",
      secret_access_key: "test-secret-key",
      security_token: "test-session-token",
      region: region
    }
  end

  defp assert_signing_region(conn, region) do
    assert [authorization] = Plug.Conn.get_req_header(conn, "authorization")

    assert authorization =~
             ~r"Credential=test-access-key/\d{8}/#{region}/bedrock-agentcore/aws4_request(?:,|$)"
  end
end
