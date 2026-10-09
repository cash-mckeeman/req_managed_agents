defmodule ReqManagedAgents.AWS.SigV4Test do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.AWS.SigV4

  @creds %{
    access_key_id: "AKID",
    secret_access_key: "secret",
    region: "us-east-1",
    security_token: nil
  }

  test "signs an explicitly selected AWS service" do
    headers =
      SigV4.sign_request(:post, "https://logs.us-east-1.amazonaws.com", "{}",
        service: "logs",
        credentials: @creds
      )

    assert {_, authorization} = Enum.find(headers, fn {name, _} -> name == "authorization" end)
    assert authorization =~ "/logs/aws4_request"
  end

  test "legacy signer retains the default AgentCore service" do
    for opts <- [[credentials: @creds], [credentials: @creds, service: nil]] do
      headers =
        ReqManagedAgents.AgentCore.SigV4.sign_request(
          :post,
          "https://example.invalid",
          "{}",
          opts
        )

      assert {_, authorization} = Enum.find(headers, fn {name, _} -> name == "authorization" end)
      assert authorization =~ "/bedrock-agentcore/aws4_request"
    end
  end

  test "requires an explicit service" do
    assert_raise KeyError, fn ->
      SigV4.sign_request(:post, "https://logs.us-east-1.amazonaws.com", "{}", credentials: @creds)
    end
  end
end
