defmodule ReqManagedAgents.AgentCore.Client do
  @moduledoc """
  SigV4-signed REST client for AWS AgentCore (`bedrock-agentcore`). Covers the
  control-plane harness lifecycle (`create_harness`/`get_harness`/`delete_harness`),
  the AgentCore Identity token-vault (`create_api_key_credential_provider`), and the
  data-plane `invoke_harness` (returns a decoded `vnd.amazon.eventstream`).

  Infra-agnostic: it knows AgentCore's model-config surface, nothing about what
  sits behind a `liteLlmModelConfig.apiBase`. Build with `new/1`; pass as the
  first arg to every call. Transport is injectable via `:req_options` for tests.

  The invoke data plane streams incrementally: `receive_timeout` on this struct governs
  control-plane calls only, while `invoke_harness/2` uses the per-invoke `:idle_timeout`
  (default 300_000 ms) as an inter-chunk liveness guard — a healthy turn may run
  arbitrarily long; only silence fails it.
  """
  alias ReqManagedAgents.AgentCore.{EventStream, SigV4}
  alias ReqManagedAgents.Providers.BedrockAgentCore.HarnessSpec

  # AgentCore has two endpoints that BOTH sign with service name "bedrock-agentcore":
  #   - control plane (CreateHarness/GetHarness/DeleteHarness, credential providers)
  #     → host bedrock-agentcore-control.<region>.amazonaws.com
  #   - data plane (InvokeHarness) → host bedrock-agentcore.<region>.amazonaws.com
  @default_base "https://bedrock-agentcore.us-east-1.amazonaws.com"
  @default_control_base "https://bedrock-agentcore-control.us-east-1.amazonaws.com"
  @max_retries 2
  @default_receive_timeout 600_000
  # Inter-chunk idle timeout for the streaming data plane.
  @default_idle_timeout 300_000

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

  @type t :: %__MODULE__{
          credentials: SigV4.creds(),
          base_url: String.t(),
          control_base_url: String.t(),
          service: String.t(),
          receive_timeout: timeout(),
          req_options: keyword()
        }

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

  # `spec` is a `HarnessSpec.t()` in production (assembled by `BedrockAgentCore.build_spec/2`)
  # but the client-level tests exercise this function directly with hand-built plain maps —
  # including ones that omit :environment/:environment_variables/:timeout_seconds entirely
  # (opaque passthrough is optional). `Map.get/2` reads a struct field exactly like dot access
  # when the key is present, and additionally tolerates a bare map where the key is absent —
  # so these three stay on `Map.get/2` rather than `spec.field` (which raises on a missing key).
  @spec create_harness(t(), HarnessSpec.t() | map()) :: {:ok, map()} | {:error, term()}
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
      |> maybe_put("environment", Map.get(spec, :environment))
      |> maybe_put("environmentVariables", Map.get(spec, :environment_variables))

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
        |> maybe_put("timeoutSeconds", inv[:timeout_seconds])
        |> maybe_put("maxIterations", inv[:max_iterations])
        |> maybe_put("maxTokens", inv[:max_tokens])

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

      case request(c, :post, url, headers, json,
             receive_timeout: inv[:idle_timeout] || @default_idle_timeout,
             into: stream_reducer(inv[:on_event])
           ) do
        {:ok, %{status: s} = resp} when s in 200..299 ->
          {:ok, streamed_events(resp)}

        {:ok, %{status: s} = resp} ->
          {:error, {:http_error, s, streamed_body(resp)}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Data-plane `InvokeAgentRuntimeCommand` — run a shell command inside the session's
  microVM (no model loop, no token cost) and collect its streamed output.

  `inv` requires `:agent_runtime_arn` (the harness/runtime ARN — it rides the URI
  path), `:runtime_session_id`, and `:command`. Optional: `:timeout_seconds`
  (server-side cap, service default 300, max 3600), `:idle_timeout` (inter-chunk
  liveness guard, default 300_000 ms), `:on_output` (fn `(:stdout | :stderr, chunk)`
  called per delta, in order), `:qualifier` (endpoint name).

  Returns `{:ok, %ReqManagedAgents.AgentCore.CommandResult{}}` — a non-zero
  `exit_code` is a RESULT, not an error. Transport/stream failures return
  `{:error, term()}`.
  """
  @spec invoke_agent_runtime_command(t(), map()) ::
          {:ok, ReqManagedAgents.AgentCore.CommandResult.t()} | {:error, term()}
  def invoke_agent_runtime_command(
        c,
        %{agent_runtime_arn: arn, runtime_session_id: sid, command: command} = inv
      ) do
    path = "/runtimes/#{URI.encode_www_form(arn)}/commands"

    span(c, :post, "/runtimes/{arn}/commands", :invoke_agent_runtime_command, fn ->
      body =
        %{"command" => command}
        |> maybe_put("timeout", inv[:timeout_seconds])

      qs =
        if inv[:qualifier],
          do: "?" <> URI.encode_query([{"qualifier", inv[:qualifier]}]),
          else: ""

      url = c.base_url <> path <> qs
      json = Jason.encode!(body)

      headers =
        SigV4.sign_request(:post, url, json,
          service: c.service,
          credentials: c.credentials,
          headers: [
            {"content-type", "application/json"},
            {"X-Amzn-Bedrock-AgentCore-Runtime-Session-Id", sid}
          ]
        )

      case request(c, :post, url, headers, json,
             receive_timeout: inv[:idle_timeout] || @default_idle_timeout,
             into: stream_reducer(command_on_event(inv[:on_output]))
           ) do
        {:ok, %{status: s} = resp} when s in 200..299 ->
          command_result_from_events(streamed_events(resp))

        {:ok, %{status: s} = resp} ->
          {:error, {:http_error, s, streamed_body(resp)}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  # Bridge decoded command events to the caller's on_output callback (per delta, in order).
  defp command_on_event(nil), do: nil

  defp command_on_event(on_output) when is_function(on_output, 2) do
    fn ev ->
      case unwrap_chunk(ev) do
        %{"contentDelta" => d} -> fire_delta_output(on_output, d)
        _ -> :ok
      end
    end
  end

  defp fire_delta_output(on_output, d) do
    if is_binary(d["stdout"]) and d["stdout"] != "", do: on_output.(:stdout, d["stdout"])
    if is_binary(d["stderr"]) and d["stderr"] != "", do: on_output.(:stderr, d["stderr"])
  end

  defp command_result(events) do
    Enum.reduce(events, %ReqManagedAgents.AgentCore.CommandResult{}, fn ev, acc ->
      case unwrap_chunk(ev) do
        %{"contentDelta" => d} ->
          %{
            acc
            | stdout: acc.stdout <> (d["stdout"] || ""),
              stderr: acc.stderr <> (d["stderr"] || "")
          }

        %{"contentStop" => stop} ->
          %{acc | exit_code: stop["exitCode"]}

        _ ->
          acc
      end
    end)
  end

  # The wire wraps command events in a "chunk" envelope; tolerate bare events too.
  defp unwrap_chunk(%{"chunk" => inner}) when is_map(inner), do: inner
  defp unwrap_chunk(ev), do: ev

  defp command_result_from_events(events) do
    case command_stream_error(events) do
      {type, message} -> {:error, {:command_stream_error, type, message}}
      nil -> {:ok, command_result(events)}
    end
  end

  defp command_stream_error(events) do
    Enum.find_value(events, fn
      %{"__stream_error__" => %{"type" => t, "message" => m}} -> {t, m}
      _ -> nil
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
    # req_options merges last and therefore overrides per-call options (including the
    # invoke path's receive_timeout-as-idle-timeout). It is the test-injection seam
    # and wins on conflict by design.
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

  # Streaming reducer for the invoke data plane: 2xx chunks decode incrementally
  # (firing on_event per decoded event, in order); non-2xx chunks accumulate raw
  # so the error tuple carries the body. With `into:` streaming, Finch applies
  # :receive_timeout per await — it is the inter-chunk idle guard, not a body cap.
  defp stream_reducer(on_event) do
    fn {:data, chunk}, {req, resp} ->
      resp =
        if resp.status in 200..299 do
          accumulate_ok_chunk(resp, chunk, on_event)
        else
          Req.Response.put_private(
            resp,
            :rma_error_body,
            Map.get(resp.private, :rma_error_body, "") <> chunk
          )
        end

      {:cont, {req, resp}}
    end
  end

  defp accumulate_ok_chunk(resp, chunk, on_event) do
    buffer = Map.get(resp.private, :rma_buffer, "") <> chunk
    {events, rest} = EventStream.decode(buffer)
    # Fire on_event in stream order (events is already ordered within the chunk).
    if on_event, do: Enum.each(events, on_event)

    # Prepend rather than append to keep accumulation O(n); streamed_events/1
    # reverses once before returning to restore stream order.
    acc = Enum.reverse(events, Map.get(resp.private, :rma_events, []))

    resp
    |> Req.Response.put_private(:rma_events, acc)
    |> Req.Response.put_private(:rma_buffer, rest)
  end

  # Compat: an injected adapter/plug that buffers (never invoking the reducer)
  # leaves resp.body as the raw binary — decode it the old way.
  defp streamed_events(resp) do
    case Map.get(resp.private, :rma_events) do
      nil when is_binary(resp.body) and resp.body != "" ->
        {events, _rest} = EventStream.decode(resp.body)
        events

      nil ->
        []

      events ->
        # The accumulator is stored in reverse (prepend-for-O(n)); restore stream order here.
        Enum.reverse(events)
    end
  end

  defp streamed_body(resp) do
    Map.get(resp.private, :rma_error_body) ||
      if(is_binary(resp.body), do: resp.body, else: "")
  end

  defp handle({:ok, %{status: s, body: body}}) when s in 200..299, do: {:ok, body}
  defp handle({:ok, %{status: s, body: body}}), do: {:error, {:http_error, s, body}}
  defp handle({:error, reason}), do: {:error, reason}
end
