defmodule ReqManagedAgents.Providers.BedrockAgentCore.InvocationLimitWireTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.AgentCore.Client, as: LegacyClient
  alias ReqManagedAgents.EventStreamFrames
  alias ReqManagedAgents.Providers.BedrockAgentCore, as: P
  alias ReqManagedAgents.Providers.BedrockAgentCore.Client

  for constructor <- [Client, LegacyClient],
      {status, redirect_option} <- [
        {503, :redirect},
        {307, :redirect},
        {307, :follow_redirects},
        {200, :redirect}
      ] do
    test "#{inspect(constructor)} bounded calls disable HTTP replay for status #{status} with #{redirect_option}" do
      bypass = Bypass.open()
      owner = self()

      options =
        [retry: :transient, max_retries: 3, retry_delay: 0] ++
          [{unquote(redirect_option), true}]

      client =
        unquote(constructor).new(
          credentials: %{
            access_key_id: "AKID",
            secret_access_key: "secret",
            region: "us-east-1",
            security_token: nil
          },
          base_url: "http://localhost:#{bypass.port}",
          req_options: options
        )

      Bypass.expect(bypass, "POST", "/harnesses/invoke", fn conn ->
        send(owner, :wire_invoke)
        assert Plug.Conn.get_req_header(conn, "authorization") |> hd() =~ "Credential=AKID/"

        assert Plug.Conn.get_req_header(conn, "authorization") |> hd() =~
                 "/us-east-1/bedrock-agentcore/aws4_request"

        assert URI.decode_query(conn.query_string) == %{"harnessArn" => "arn:new"}
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "messages" => [%{"role" => "user", "content" => [%{"text" => "hello"}]}]
               }

        case unquote(status) do
          307 ->
            conn
            |> Plug.Conn.put_resp_header(
              "location",
              "http://localhost:#{bypass.port}/harnesses/invoke?harnessArn=arn%3Anew"
            )
            |> Plug.Conn.resp(307, "redirect")

          503 ->
            Plug.Conn.resp(conn, 503, "unavailable")

          200 ->
            body =
              EventStreamFrames.frame(
                Jason.encode!(%{"messageStop" => %{"stopReason" => "end_turn"}})
              )

            conn
            |> Plug.Conn.put_resp_content_type("application/vnd.amazon.eventstream")
            |> Plug.Conn.resp(200, body)
        end
      end)

      {:ok, conn} =
        P.open(
          [
            client: client,
            harness_arn: "arn:new",
            runtime_session_id: String.duplicate("s", 33),
            max_invocation_attempts: 1,
            invoke_retries: 3
          ],
          nil
        )

      result = P.poll_turn(conn, P.user_input("hello"))

      if unquote(status) == 200 do
        assert {:ok, [%{"messageStop" => %{"stopReason" => "end_turn"}}], _} = result
      else
        assert result == {:error, {:max_invocation_attempts_exceeded, 1}}
      end

      assert_receive :wire_invoke
      refute_receive :wire_invoke
      assert client.req_options == options
    end
  end
end
