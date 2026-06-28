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

  @default_base "https://bedrock-agentcore.us-east-1.amazonaws.com"
  @max_retries 2

  defstruct [
    :credentials,
    base_url: @default_base,
    service: "bedrock-agentcore",
    receive_timeout: 600_000,
    req_options: []
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      credentials: opts[:credentials] || SigV4.from_env(),
      base_url: opts[:base_url] || @default_base,
      service: opts[:service] || "bedrock-agentcore",
      receive_timeout: opts[:receive_timeout] || 600_000,
      req_options: opts[:req_options] || []
    }
  end

  @spec create_harness(t(), map()) :: {:ok, map()} | {:error, term()}
  def create_harness(c, spec) do
    body = %{
      "name" => spec.name,
      "instruction" => spec.system_prompt,
      "tools" => spec.tools,
      "model" => spec.model
    }

    post_json(c, "/harnesses", body)
  end

  @spec get_harness(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_harness(c, id), do: get_json(c, "/harnesses/#{id}")

  @spec delete_harness(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_harness(c, id), do: delete_json(c, "/harnesses/#{id}")

  @spec create_api_key_credential_provider(t(), map()) :: {:ok, map()} | {:error, term()}
  def create_api_key_credential_provider(c, %{name: name, api_key: key}),
    do: post_json(c, "/credential-providers/api-key", %{"name" => name, "apiKey" => key})

  @doc """
  Data-plane `InvokeHarness`. Posts `messages` on a `runtimeSessionId` and returns
  the decoded event-stream maps. Resume is just another call with the resume
  messages (the profile assembles them).
  """
  @spec invoke_harness(t(), map()) :: {:ok, [map()]} | {:error, term()}
  def invoke_harness(c, %{harness_id: id, runtime_session_id: sid, messages: messages} = inv) do
    body =
      %{"runtimeSessionId" => sid, "messages" => messages}
      |> maybe_put("model", inv[:model])
      |> maybe_put("systemPrompt", inv[:system_prompt])

    url = c.base_url <> "/harnesses/#{id}/invocations"
    json = Jason.encode!(body)

    case raw_post(c, url, json, decode_body: false) do
      {:ok, %{status: s, body: raw}} when s in 200..299 ->
        {events, _rest} = EventStream.decode(raw)
        {:ok, events}

      {:ok, %{status: s, body: body}} ->
        {:error, {:http_error, s, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp post_json(c, path, body) do
    url = c.base_url <> path
    json = Jason.encode!(body)
    c |> raw_post(url, json) |> handle()
  end

  defp get_json(c, path) do
    url = c.base_url <> path
    headers = SigV4.sign_request(:get, url, "", service: c.service, credentials: c.credentials)
    c |> request(:get, url, headers, "", retry: :transient, max_retries: @max_retries) |> handle()
  end

  defp delete_json(c, path) do
    url = c.base_url <> path
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
      receive_timeout: c.receive_timeout
    ]
    |> Keyword.merge(extra)
    |> Req.new()
    |> Req.merge(c.req_options)
    |> Req.request(method: method, body: body)
  end

  defp handle({:ok, %{status: s, body: body}}) when s in 200..299, do: {:ok, body}
  defp handle({:ok, %{status: s, body: body}}), do: {:error, {:http_error, s, body}}
  defp handle({:error, reason}), do: {:error, reason}
end
