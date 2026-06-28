defmodule Mix.Tasks.ReqManagedAgents.AgentCore.Smoke do
  @shortdoc "End-to-end AgentCore Harness smoke: SigV4 → EventStream → tool loop → resume"

  @moduledoc """
  Drives the full `req_managed_agents` AgentCore Harness client stack end-to-end
  as a single repeatable command — no live AWS needed.

  ## What it covers

  The stub Req adapter intercepts at the transport seam so SigV4 signing, JSON
  encoding, EventStream decoding, Converse parsing, and the tool→resume loop all
  run in-process against real production code. The adapter returns valid
  event-stream binary frames for each turn; the loop runs to an `end_turn`
  terminal.

  Eight stages are verified:

  1. **SigV4 header well-formed** — `SigV4.sign_request/4` produces
     `authorization` + `x-amz-date` headers.
  2. **EventStream multi-frame + remainder** — decode two complete frames and a
     5-byte truncated third; expect 2 messages and a non-empty remainder.
  3. **Converse.inline_function shape** — a NimbleOptions schema maps to a
     `config.inlineFunction.inputSchema` (bare JSON Schema, no `json` wrapper) with the expected property.
  4. **SigV4 signed** — every `invoke_harness` request carried an
     `AWS4-HMAC-SHA256` Authorization header.
  5. **tool_use decoded+parsed** — the loop actually ran the tool (the resume
     turn fired).
  6. **strict resume contract** — the resume body contained BOTH `assistant`
     (toolUse) and `user` (toolResult) roles.
  7. **tool text round-trip** — the toolResult text in the resume body equals
     `"echoed: hi"`.
  8. **terminal end_turn** — `invoke_to_completion` returned
     `{:ok, %{terminal: :end_turn, stop_reason: "end_turn"}}`.

  ## Usage

      mix req_managed_agents.agent_core.smoke

  Exits 0 on all-pass, non-zero on any failure.
  """

  use Mix.Task

  alias ReqManagedAgents.AgentCore
  alias ReqManagedAgents.AgentCore.{Client, Converse, EventStream, SigV4}

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:req_managed_agents)

    case run_smoke() do
      {:ok, results} ->
        print_results(results)
        Mix.shell().info("\nAll #{length(results)} stages passed.")
        :ok

      {:error, results} ->
        print_results(results)
        fails = Enum.count(results, fn {_, s, _} -> s == :fail end)
        Mix.raise("#{fails} smoke stage(s) failed.")
    end
  end

  @doc """
  Pure smoke flow — returns `{:ok, results}` or `{:error, results}` where
  `results` is a list of `{stage_name, :pass | :fail, detail}`.

  Does not print or halt; suitable for calling directly from tests.
  """
  @spec run_smoke() ::
          {:ok, [{String.t(), :pass | :fail, String.t()}]}
          | {:error, [{String.t(), :pass | :fail, String.t()}]}
  def run_smoke do
    standalone = [
      sigv4_standalone_stage(),
      event_stream_standalone_stage(),
      converse_standalone_stage()
    ]

    {:ok, collector} =
      Agent.start_link(fn ->
        %{auth_checks: [], resume_seen: false, resume_roles: [], tool_result_text: nil}
      end)

    adapter = build_adapter(collector)

    client =
      Client.new(
        credentials: %{
          access_key_id: "AKIDSMOKE",
          secret_access_key: "smoke-secret",
          region: "us-east-1",
          security_token: nil
        },
        base_url: "https://bedrock-agentcore.us-east-1.amazonaws.com",
        req_options: [adapter: adapter]
      )

    invoke_result =
      AgentCore.invoke_to_completion(
        handler: fn "echo", %{"text" => t}, _ctx -> {:ok, "echoed: #{t}"} end,
        context: %{},
        harness_arn: "arn:aws:bedrock-agentcore:us-east-1:123456789012:harness/ba",
        runtime_session_id: "smoke-session-id-long-enough-for-min-33-chars",
        prompt: "begin",
        client: client,
        timeout: 5_000
      )

    state = Agent.get(collector, & &1)
    Agent.stop(collector)

    results = standalone ++ build_loop_results(state, invoke_result)

    if Enum.all?(results, fn {_, s, _} -> s == :pass end) do
      {:ok, results}
    else
      {:error, results}
    end
  end

  # ---------------------------------------------------------------------------
  # Standalone sanity stages (no invoke loop)
  # ---------------------------------------------------------------------------

  defp sigv4_standalone_stage do
    creds = %{
      access_key_id: "AKIDTEST",
      secret_access_key: "testsecret",
      region: "us-east-1",
      security_token: nil
    }

    url = "https://bedrock-agentcore.us-east-1.amazonaws.com/harnesses/test/invocations"
    body = ~s({"runtimeSessionId":"s1","messages":[]})

    headers = SigV4.sign_request(:post, url, body, credentials: creds)

    has_auth =
      Enum.any?(headers, fn {k, v} ->
        k == "authorization" and String.starts_with?(v, "AWS4-HMAC-SHA256")
      end)

    has_date = Enum.any?(headers, fn {k, _} -> k == "x-amz-date" end)

    if has_auth and has_date do
      {"SigV4 header well-formed", :pass, "authorization (AWS4-HMAC-SHA256) + x-amz-date present"}
    else
      {"SigV4 header well-formed", :fail,
       "header names present: #{inspect(Enum.map(headers, fn {k, _} -> k end))}"}
    end
  end

  defp event_stream_standalone_stage do
    # Realistic form: :event-type header carries the type; payload is the UNWRAPPED inner map.
    f1 = frame_with_event_type("messageStop", ~s({"stopReason":"end_turn"}))

    f2 =
      frame_with_event_type(
        "contentBlockDelta",
        ~s({"contentBlockIndex":0,"delta":{"text":"hi"}})
      )

    # Truncate a third frame to 5 bytes — should become the remainder
    f3_full = frame_with_event_type("extra", ~s({"data":true}))
    f3_partial = binary_part(f3_full, 0, 5)

    {messages, remainder} = EventStream.decode(f1 <> f2 <> f3_partial)

    if length(messages) == 2 and byte_size(remainder) > 0 do
      {"EventStream multi-frame + remainder", :pass,
       "2 messages decoded; #{byte_size(remainder)}-byte remainder retained"}
    else
      {"EventStream multi-frame + remainder", :fail,
       "messages=#{length(messages)}, remainder=#{byte_size(remainder)} bytes"}
    end
  end

  defp converse_standalone_stage do
    result =
      Converse.inline_function("echo", "Echo tool", topic: [type: :string, required: true])

    topic_type =
      get_in(result, ["config", "inlineFunction", "inputSchema", "properties", "topic", "type"])

    if topic_type == "string" do
      {"Converse.inline_function shape", :pass,
       "config.inlineFunction.inputSchema has topic property with type \"string\" (bare JSON Schema)"}
    else
      {"Converse.inline_function shape", :fail, "got topic type: #{inspect(topic_type)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Loop stages — built from collector state + invoke_result
  # ---------------------------------------------------------------------------

  defp build_loop_results(state, invoke_result) do
    [
      sigv4_signed_stage(state),
      tool_use_stage(state),
      resume_contract_stage(state),
      tool_text_stage(state),
      terminal_stage(invoke_result)
    ]
  end

  defp sigv4_signed_stage(%{auth_checks: checks}) do
    if length(checks) > 0 and Enum.all?(checks, & &1) do
      {"SigV4 signed", :pass,
       "#{length(checks)} invoke request(s) carried AWS4-HMAC-SHA256 Authorization"}
    else
      {"SigV4 signed", :fail, "auth_checks: #{inspect(checks)}"}
    end
  end

  defp tool_use_stage(%{resume_seen: true}) do
    {"tool_use decoded+parsed", :pass, "tool loop ran; resume turn was reached"}
  end

  defp tool_use_stage(_) do
    {"tool_use decoded+parsed", :fail, "resume turn never fired"}
  end

  defp resume_contract_stage(%{resume_roles: ["assistant", "user"]}) do
    {"strict resume contract", :pass, "resume body roles: [\"assistant\", \"user\"]"}
  end

  defp resume_contract_stage(%{resume_roles: roles}) do
    {"strict resume contract", :fail, "resume roles: #{inspect(roles)}"}
  end

  defp tool_text_stage(%{tool_result_text: "echoed: hi"}) do
    {"tool text round-trip", :pass, "toolResult text == \"echoed: hi\""}
  end

  defp tool_text_stage(%{tool_result_text: got}) do
    {"tool text round-trip", :fail, "got: #{inspect(got)}"}
  end

  defp terminal_stage({:ok, %{terminal: :end_turn, stop_reason: "end_turn"}}) do
    {"terminal end_turn", :pass,
     "invoke_to_completion returned {:ok, %{terminal: :end_turn, stop_reason: \"end_turn\"}}"}
  end

  defp terminal_stage({:ok, other}) do
    {"terminal end_turn", :fail, "unexpected ok result: #{inspect(other)}"}
  end

  defp terminal_stage({:error, reason}) do
    {"terminal end_turn", :fail, "error: #{inspect(reason)}"}
  end

  # ---------------------------------------------------------------------------
  # Stub adapter
  # ---------------------------------------------------------------------------

  # Builds a Req adapter closure that intercepts transport, records observations
  # in `collector`, and returns pre-built event-stream frames. SigV4 signing,
  # JSON encoding, EventStream decoding, Converse parsing, and the tool loop all
  # run for real — only the HTTP call is replaced.
  defp build_adapter(collector) do
    fn req ->
      # Record whether this request carried a valid AWS4-HMAC-SHA256 auth header.
      auth_values = Req.Request.get_header(req, "authorization")

      has_aws4 =
        Enum.any?(auth_values, &String.starts_with?(&1, "AWS4-HMAC-SHA256"))

      Agent.update(
        collector,
        &Map.update(&1, :auth_checks, [has_aws4], fn checks -> [has_aws4 | checks] end)
      )

      # Determine which turn this is by inspecting the last message's content.
      body_map = Jason.decode!(req.body)
      messages = body_map["messages"]
      last = List.last(messages)
      last_content = last["content"] || []

      frames =
        if Enum.any?(last_content, &Map.has_key?(&1, "toolResult")) do
          # Resume turn — record roles and toolResult text for assertions.
          roles = Enum.map(messages, & &1["role"])

          tool_result_text =
            get_in(last_content, [
              Access.at(0),
              "toolResult",
              "content",
              Access.at(0),
              "text"
            ])

          Agent.update(collector, fn s ->
            %{s | resume_seen: true, resume_roles: roles, tool_result_text: tool_result_text}
          end)

          turn2_frames()
        else
          # Initial turn
          turn1_frames()
        end

      resp =
        Req.Response.new(
          status: 200,
          headers: [{"content-type", "application/vnd.amazon.eventstream"}],
          body: frames
        )

      {req, resp}
    end
  end

  # ---------------------------------------------------------------------------
  # Frame builders
  # ---------------------------------------------------------------------------

  # Turn 1: a tool_use turn — contentBlockStart + contentBlockDelta + messageStop.
  # Realistic form: :event-type header carries the type; payload is the UNWRAPPED inner map
  # (no outer event-type key in the JSON body), matching what AgentCore live streams deliver.
  defp turn1_frames do
    frame_with_event_type(
      "contentBlockStart",
      ~s({"contentBlockIndex":0,"start":{"toolUse":{"toolUseId":"tu_1","name":"echo"}}})
    ) <>
      frame_with_event_type(
        "contentBlockDelta",
        ~s({"contentBlockIndex":0,"delta":{"toolUse":{"input":"{\\"text\\":\\"hi\\"}"}}})
      ) <>
      frame_with_event_type("messageStop", ~s({"stopReason":"tool_use"}))
  end

  # Turn 2: a terminal end_turn — contentBlockDelta(text) + messageStop
  defp turn2_frames do
    frame_with_event_type(
      "contentBlockDelta",
      ~s({"contentBlockIndex":0,"delta":{"text":"all done."}})
    ) <>
      frame_with_event_type("messageStop", ~s({"stopReason":"end_turn"}))
  end

  # Builds a frame with a single :event-type string header (type 7) carrying the
  # given event type, and the unwrapped JSON payload in the body. This mirrors the
  # real AgentCore Converse stream wire format (vs. the old "outer key in body" shape).
  defp frame_with_event_type(event_type, payload_json) when is_binary(payload_json) do
    headers_bin = str_header(":event-type", event_type)
    total_len = 12 + byte_size(headers_bin) + byte_size(payload_json) + 4
    prelude = <<total_len::big-32, byte_size(headers_bin)::big-32>>
    prelude_crc = :erlang.crc32(prelude)
    body = prelude <> <<prelude_crc::32>> <> headers_bin <> payload_json
    message_crc = :erlang.crc32(body)
    body <> <<message_crc::32>>
  end

  # Encodes a string key-value header in the AWS Event Stream wire format:
  # name-len(1B) + name + value-type(1B=7 for string) + value-len(2B big-endian) + value.
  defp str_header(name, value) do
    <<byte_size(name)::8, name::binary, 7::8, byte_size(value)::big-16, value::binary>>
  end

  # ---------------------------------------------------------------------------
  # Printer
  # ---------------------------------------------------------------------------

  defp print_results(results) do
    Enum.each(results, fn {name, status, detail} ->
      tag = if status == :pass, do: "[PASS]", else: "[FAIL]"
      Mix.shell().info("#{tag} #{name} — #{detail}")
    end)
  end
end
