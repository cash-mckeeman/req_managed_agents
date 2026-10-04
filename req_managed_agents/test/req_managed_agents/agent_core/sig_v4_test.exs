defmodule ReqManagedAgents.AgentCore.SigV4Test do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.AgentCore.SigV4

  @creds %{
    access_key_id: "AKIDEXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    region: "us-east-1",
    security_token: nil
  }

  test "signs a bedrock-agentcore POST with an AWS4-HMAC-SHA256 Authorization + x-amz-date" do
    url = "https://bedrock-agentcore.us-east-1.amazonaws.com/harnesses/h-123/invocations"
    body = ~s({"runtimeSessionId":"s1"})

    headers =
      SigV4.sign_request(:post, url, body,
        service: "bedrock-agentcore",
        credentials: @creds,
        headers: [{"content-type", "application/json"}]
      )

    auth = headers |> Enum.find(fn {k, _} -> String.downcase(k) == "authorization" end) |> elem(1)
    assert auth =~ "AWS4-HMAC-SHA256"
    assert auth =~ "Credential=AKIDEXAMPLE/"
    assert auth =~ "/us-east-1/bedrock-agentcore/aws4_request"
    assert auth =~ "SignedHeaders="
    assert auth =~ "Signature="
    assert Enum.any?(headers, fn {k, _} -> String.downcase(k) == "x-amz-date" end)
  end

  test "includes x-amz-security-token when a session token is present" do
    creds = %{@creds | security_token: "FQoGZX..."}
    url = "https://bedrock-agentcore.us-east-1.amazonaws.com/harnesses/h-1/invocations"

    headers =
      SigV4.sign_request(:post, url, "{}", service: "bedrock-agentcore", credentials: creds)

    assert Enum.any?(headers, fn {k, _} -> String.downcase(k) == "x-amz-security-token" end)
  end
end
