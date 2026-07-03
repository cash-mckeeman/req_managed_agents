defmodule ReqManagedAgents.AgentCore.Client do
  @moduledoc """
  SigV4-signed REST client for AWS AgentCore (`bedrock-agentcore`). Covers the
  control-plane harness lifecycle (`create_harness`/`get_harness`/`delete_harness`),
  the AgentCore Identity token-vault (`create_api_key_credential_provider`), and the
  data-plane `invoke_harness` (returns a decoded `vnd.amazon.eventstream`).

  Infra-agnostic: it knows AgentCore's model-config surface, nothing about what
  sits behind a `liteLlmModelConfig.apiBase`. Build with `new/1`; pass as the
  first arg to every call. Transport is injectable via `:req_options` for tests.
  """
  alias ReqManagedAgents.AgentCore.{SigV4, EventStream}

  # AgentCore has two endpoints that BOTH sign with service name "bedrock-agentcore":
  #   - control plane (CreateHarness/GetHarness/DeleteHarness, credential providers)
  #     → host bedrock-agentcore-control.<region>.amazonaws.com
  #   - data plane (InvokeHarness) → host bedrock-agentcore.<region>.amazonaws.com
  @default_base "https://bedrock-agentcore.us-east-1.amazonaws.com"
  @default_control_base "https://bedrock-agentcore-control.us-east-1.amazonaws.com"
  @max_retries 2
  @default_receive_timeout 600_000

  # credentials (secret key + session token) must never appear in inspect
  # output — see the equivalent guard on ReqManagedAgents.Client.
  @derive {Inspect, except: [:credentials]}
  defstruct [
    :credentials,
    base_url: @default_base,
    control_base_url: @default_control_base,
    service: "bedrock-agentcore",
    receive_timeout: @default_receive_timeout,
    req_options: []
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      credentials: opts[:credentials] || SigV4.from_env(),
      base_url: opts[:base_url] || @default_base,
      control_base_url: opts[:control_base_url] || opts[:base_url] || @default_control_base,
      service: opts[:service] || "bedrock-agentcore",
      receive_timeout: opts[:receive_timeout] || @default_receive_timeout,
      req_options: opts[:req_options] || []
    }
  end

  @spec create_harness(t(), map()) :: {:ok, map()} | {:error, term()}
  def create_harness(c, spec) do
    body =
      %{
        "harnessName" => spec.name,
        "executionRoleArn" => spec.execution_role_arn,
        "systemPrompt" => system_prompt_blocks(spec.system_prompt),
        "model" => spec.model,
        "tools" => spec.tools
      }
      |> maybe_put("timeoutSeconds", Map.get(spec, :timeout_seconds))

    span(c, :post, "/harnesses", :create_harness, fn -> post_json(c, "/harnesses", body) end)
  end

  @spec get_harness(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_harness(c, id),
    do: span(c, :get, "/harnesses/#{id}", :get_harness, fn -> get_json(c, "/harnesses/#{id}") end)

  @doc """
  `ListHarnesses` (control plane). Returns the decoded body
  `%{"harnesses" => [%{"harnessName", "harnessId", "arn", "status", ...}], "nextToken" => ...}`.
  Used to recover an existing harness by name (idempotent provisioning) when a
  `CreateHarness` collides with a previously-created harness of the same name.
  """
  @spec list_harnesses(t()) :: {:ok, map()} | {:error, term()}
  def list_harnesses(c),
    do: span(c, :get, "/harnesses", :list_harnesses, fn -> get_json(c, "/harnesses") end)

  @spec delete_harness(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_harness(c, id),
    do:
      span(c, :delete, "/harnesses/#{id}", :delete_harness, fn ->
        delete_json(c, "/harnesses/#{id}")
      end)

  @spec create_api_key_credential_provider(t(), map()) :: {:ok, map()} | {:error, term()}
  def create_api_key_credential_provider(c, %{name: name, api_key: key}),
    do:
      span(c, :post, "/credential-providers/api-key", :create_api_key_credential_provider, fn ->
        post_json(c, "/credential-providers/api-key", %{"name" => name, "apiKey" => key})
      end)

  @doc """
  Data-plane `InvokeHarness`. Sends `messages` with `harnessArn` in the query
  string and the required `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` header.
  Returns the decoded event-stream maps. Resume is just another call with the
  resume messages (the profile assembles them).

  Note: AWS requires `runtimeSessionId` to be at least 33 characters long
  (pattern `[a-zA-Z0-9][a-zA-Z0-9-_]*`, max 100). The client passes it through
  as-is — the caller is responsible for supplying a conforming value.
  """
  @spec invoke_harness(t(), map()) :: {:ok, [map()]} | {:error, term()}
  def invoke_harness(c, %{harness_arn: arn, runtime_session_id: sid, messages: messages} = inv) do
    path = "/harnesses/invoke"

    span(c, :post, path, :invoke_harness, fn ->
      body =
        %{"messages" => messages}
        |> maybe_put("model", inv[:model])
        |> maybe_put("systemPrompt", system_prompt_blocks(inv[:system_prompt]))

      qs_params =
        [{"harnessArn", arn}] ++
          if(inv[:qualifier], do: [{"qualifier", inv[:qualifier]}], else: [])

      url = c.base_url <> path <> "?" <> URI.encode_query(qs_params)
      json = Jason.encode!(body)

      base_headers =
        [
          {"content-type", "application/json"},
          {"X-Amzn-Bedrock-AgentCore-Runtime-Session-Id", sid}
        ] ++
          if(inv[:runtime_user_id],
            do: [{"X-Amzn-Bedrock-AgentCore-Runtime-User-Id", inv[:runtime_user_id]}],
            else: []
          )

      headers =
        SigV4.sign_request(:post, url, json,
          service: c.service,
          credentials: c.credentials,
          headers: base_headers
        )

      case request(c, :post, url, headers, json, decode_body: false) do
        {:ok, %{status: s, body: raw}} when s in 200..299 ->
          {events, _rest} = EventStream.decode(raw)
          {:ok, events}

        {:ok, %{status: s, body: body}} ->
          {:error, {:http_error, s, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # HarnessSystemPrompt is a LIST of {text: string} content blocks (Converse-style),
  # not a bare string. Wrap a string; pass a list/nil through.
  defp system_prompt_blocks(nil), do: nil
  defp system_prompt_blocks(prompt) when is_binary(prompt), do: [%{"text" => prompt}]
  defp system_prompt_blocks(blocks) when is_list(blocks), do: blocks

  # post_json/get_json/delete_json serve the CONTROL plane (harness lifecycle +
  # credential providers) → control_base_url. Only invoke_harness uses base_url (data).
  defp post_json(c, path, body) do
    url = c.control_base_url <> path
    json = Jason.encode!(body)
    c |> raw_post(url, json) |> handle()
  end

  defp get_json(c, path) do
    url = c.control_base_url <> path
    headers = SigV4.sign_request(:get, url, "", service: c.service, credentials: c.credentials)
    c |> request(:get, url, headers, "", retry: :transient, max_retries: @max_retries) |> handle()
  end

  defp delete_json(c, path) do
    url = c.control_base_url <> path
    headers = SigV4.sign_request(:delete, url, "", service: c.service, credentials: c.credentials)

    c
    |> request(:delete, url, headers, "", retry: :transient, max_retries: @max_retries)
    |> handle()
  end

  # Sign and dispatch a POST; returns the raw Req result (no handle/1 applied).
  # Callers must handle the result themselves — post_json/3 applies handle/1,
  # invoke_harness/2 pattern-matches on status and decodes the event stream.
  defp raw_post(c, url, json, extra \\ []) do
    headers = SigV4.sign_request(:post, url, json, service: c.service, credentials: c.credentials)
    request(c, :post, url, headers, json, extra)
  end

  defp request(c, method, url, headers, body, extra) do
    [
      url: url,
      headers: headers,
      receive_timeout: c.receive_timeout,
      connect_options: [transport_opts: [keepalive: true]]
    ]
    |> Keyword.merge(extra)
    |> Req.new()
    |> Req.merge(c.req_options)
    |> Req.request(method: method, body: body)
  end

  defp span(c, method, path, op, fun) do
    meta = %{service: c.service, method: method, path: path, operation: op}

    :telemetry.span([:req_managed_agents, :agent_core, :request], meta, fn ->
      result = fun.()
      {result, Map.put(meta, :status, status_for(result))}
    end)
  end

  defp status_for({:ok, _}), do: 200
  defp status_for({:error, {:http_error, s, _}}), do: s
  defp status_for(_), do: nil

  defp handle({:ok, %{status: s, body: body}}) when s in 200..299, do: {:ok, body}
  defp handle({:ok, %{status: s, body: body}}), do: {:error, {:http_error, s, body}}
  defp handle({:error, reason}), do: {:error, reason}
end
