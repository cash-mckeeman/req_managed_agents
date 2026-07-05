defmodule ReqManagedAgents.AgentCore.SigV4 do
  @moduledoc """
  SigV4 request signing for the `bedrock-agentcore` AWS service, reusing the
  `:ex_aws_auth` signer. The signer is service-parameterized, so the same call
  signs both the data plane (`bedrock-agentcore.<region>`) and the control plane
  (`bedrock-agentcore-control.<region>`) — pass `service: "bedrock-agentcore"`.

  Infra-agnostic: credentials come from the caller or ENV; nothing here knows
  about any particular endpoint behind the URL.
  """

  alias ReqManagedAgents.AgentCore.Deps
  alias ReqManagedAgents.Config

  @type creds :: %{
          access_key_id: String.t(),
          secret_access_key: String.t(),
          region: String.t(),
          security_token: String.t() | nil
        }

  @doc """
  Return the signed header list for `method`/`url`/`body`. Caller attaches these
  to the request. `:credentials` defaults to `from_env/1`; `:service` defaults to
  `"bedrock-agentcore"`; `:headers` are base headers folded into the canonical set.

  Returns a list of `{header_name, header_value}` tuples. The `authorization` and
  `x-amz-date` headers are always present; `x-amz-security-token` is included when
  a `security_token` is set in the credentials.
  """
  @spec sign_request(atom(), String.t(), iodata(), keyword()) :: [{String.t(), String.t()}]
  def sign_request(method, url, body, opts \\ []) do
    Deps.ensure!()
    service = opts[:service] || "bedrock-agentcore"
    creds = opts[:credentials] || from_env()
    base_headers = opts[:headers] || [{"content-type", "application/json"}]

    aws_creds =
      struct!(AWSAuth.Credentials,
        access_key_id: creds.access_key_id,
        secret_access_key: creds.secret_access_key,
        region: creds.region,
        session_token: creds[:security_token]
      )

    method_str = method |> to_string() |> String.upcase()

    AWSAuth.sign_authorization_header(
      aws_creds,
      method_str,
      url,
      service,
      headers: Map.new(base_headers),
      payload: IO.iodata_to_binary(body)
    )
  end

  @doc """
  Resolve credentials from `opts`, application env, or the standard AWS_*
  env vars (session-token aware). Called with no args by default, so plain
  `from_env()` callers keep working unchanged.
  """
  @spec from_env(keyword()) :: creds()
  def from_env(opts \\ []) do
    %{
      access_key_id: Config.resolve!(opts, :aws_access_key_id, "AWS_ACCESS_KEY_ID"),
      secret_access_key: Config.resolve!(opts, :aws_secret_access_key, "AWS_SECRET_ACCESS_KEY"),
      region:
        Config.resolve(opts, :aws_region, "AWS_REGION") || System.get_env("AWS_DEFAULT_REGION") ||
          "us-east-1",
      security_token: Config.resolve(opts, :aws_session_token, "AWS_SESSION_TOKEN")
    }
  end
end
