# AgentCore Long-Run Posture (Streaming Liveness) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the whole-body-buffered `InvokeHarness` transport with incremental streaming guarded by an inter-chunk idle timeout, deliver events live to the handler/telemetry, and expose the per-invocation server budgets (`timeoutSeconds`/`maxIterations`/`maxTokens`).

**Architecture:** All transport changes live inside `ReqManagedAgents.AgentCore.Client.invoke_harness/2` (a Req `into:` reducer feeding the already-incremental `EventStream.decode/1`). `Providers.BedrockAgentCore.open/2` captures the Session pid (its previously ignored `subscriber` arg) and hands the transport an `on_event` that sends `{:provider_event, ev}` messages. `Session` grows one `handle_info` clause plus a skip-batch rule so each event reaches the handler exactly once per attempt. The Provider behaviour is untouched.

**Tech Stack:** Elixir, ExUnit, Req 0.6 (`into:` streaming), Bypass (real chunked HTTP), `aws_event_stream` via `ReqManagedAgents.AgentCore.EventStream`.

**Spec:** `docs/superpowers/specs/2026-07-02-agentcore-long-run-posture-design.md`

## Global Constraints

- **jj, not git**: commit with `jj describe -m '<msg>' && jj new` (never `git add/commit`). Run from the workspace root `.claude/worktrees/rma-ci-pipeline/`.
- **Contract freeze:** `Client.invoke_harness/2` keeps returning `{:ok, [event]} | {:error, reason}`; `{:error, {:http_error, status, body}}` on non-2xx; existing tests in `test/req_managed_agents/agent_core/client_test.exs` must keep passing unmodified.
- **Defaults (spec §3):** `:idle_timeout` default `300_000` ms (client-side, per chunk); `:timeout_seconds`/`:max_iterations`/`:max_tokens` default nil → absent from the wire body (harness defaults rule). Wire names: `"timeoutSeconds"`, `"maxIterations"`, `"maxTokens"`.
- **No client wall-clock cap on a turn.** Only the idle timeout guards the transport.
- **Control-plane calls unchanged** (buffered, `c.receive_timeout`).
- **No MIM-refs in lib/ moduledocs** (they ship to hexdocs); test files and docs/superpowers may reference MIM-50.
- **Quality gates per task:** `mix format`, full `mix test` green before each commit.

---

### Task 1: Streaming transport — Req `into:` reducer + idle timeout in `Client.invoke_harness/2`

The load-bearing task. Falsifies the design's transport assumption first: with `into:` streaming, Finch's `receive_timeout` applies per await (inter-chunk), not whole-body. If the "steady chunks" test below cannot pass with any correct implementation, STOP and report — the fallback (per spec §1/D4) is `Finch.stream/5` on this one call path, a design change needing review.

**Files:**
- Create: `test/support/event_stream_frames.ex`
- Modify: `lib/req_managed_agents/agent_core/client.ex` (the `invoke_harness/2` function + two new private helpers)
- Test: `test/req_managed_agents/agent_core/client_stream_test.exs` (new file)

**Interfaces:**
- Consumes: `ReqManagedAgents.AgentCore.EventStream.decode/1 :: binary -> {[map()], binary()}` (already incremental).
- Produces: `Client.invoke_harness(client, inv)` now honoring `inv[:idle_timeout]` (integer ms, default `300_000`) and `inv[:on_event]` (nil in this task — wired in Task 2). Test helper `ReqManagedAgents.EventStreamFrames.frame(payload_json) :: binary()`.

- [ ] **Step 1: Write the frame helper (test support, no test needed — it's exercised by every test below)**

```elixir
# test/support/event_stream_frames.ex
defmodule ReqManagedAgents.EventStreamFrames do
  @moduledoc false
  # Minimal vnd.amazon.eventstream encoder for tests: a headerless frame whose
  # JSON payload passes through EventStream.decode/1 as the envelope itself
  # (no :event-type header -> payload emitted as-is).
  def frame(payload) when is_binary(payload) do
    headers = <<>>
    prelude = <<12 + byte_size(headers) + byte_size(payload) + 4::32, byte_size(headers)::32>>
    signed = prelude <> <<:erlang.crc32(prelude)::32>> <> headers <> payload
    signed <> <<:erlang.crc32(signed)::32>>
  end
end
```

- [ ] **Step 2: Write the failing tests**

```elixir
# test/req_managed_agents/agent_core/client_stream_test.exs
defmodule ReqManagedAgents.AgentCore.ClientStreamTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.AgentCore.Client
  import ReqManagedAgents.EventStreamFrames, only: [frame: 1]

  @creds %{
    access_key_id: "AKID",
    secret_access_key: "secret",
    region: "us-east-1",
    security_token: nil
  }

  @sid "test-session-id-long-enough-to-satisfy-min-length-33"
  @arn "arn:aws:bedrock-agentcore:us-east-1:123456789012:harness/ba"

  defp inv(extra \\ []) do
    Map.merge(
      %{
        harness_arn: @arn,
        runtime_session_id: @sid,
        messages: [%{"role" => "user", "content" => [%{"text" => "hi"}]}]
      },
      Map.new(extra)
    )
  end

  setup do
    bypass = Bypass.open()
    client = Client.new(credentials: @creds, base_url: "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass, client: client}
  end

  # Sends each binary in `chunks` with `gap_ms` sleep BEFORE each send.
  defp chunked(conn, chunks, gap_ms) do
    conn = Plug.Conn.send_chunked(conn, 200)

    Enum.reduce(chunks, conn, fn part, conn ->
      Process.sleep(gap_ms)

      case Plug.Conn.chunk(conn, part) do
        {:ok, conn} -> conn
        {:error, :closed} -> conn
      end
    end)
  end

  test "MIM-50: a turn longer than idle_timeout succeeds while chunks keep flowing", %{
    bypass: bypass,
    client: client
  } do
    # 6 gaps x 100ms = 600ms total > 400ms idle_timeout; each gap < 400ms.
    frames =
      Enum.map(1..5, fn i ->
        frame(~s({"contentBlockDelta":{"contentBlockIndex":0,"delta":{"text":"t#{i}"}}}))
      end) ++ [frame(~s({"messageStop":{"stopReason":"end_turn"}}))]

    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      chunked(conn, frames, 100)
    end)

    assert {:ok, events} = Client.invoke_harness(client, inv(idle_timeout: 400))
    assert %{"messageStop" => %{"stopReason" => "end_turn"}} = List.last(events)
    assert length(events) == 6
  end

  test "MIM-50: a stream that stalls beyond idle_timeout fails with a transport timeout", %{
    bypass: bypass,
    client: client
  } do
    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      {:ok, conn} =
        Plug.Conn.chunk(conn, frame(~s({"messageStart":{"role":"assistant"}})))

      # Stall past the client's idle timeout; the client must abandon the turn.
      Process.sleep(800)

      case Plug.Conn.chunk(conn, frame(~s({"messageStop":{"stopReason":"end_turn"}}))) do
        {:ok, conn} -> conn
        {:error, :closed} -> conn
      end
    end)

    assert {:error, %Req.TransportError{reason: :timeout}} =
             Client.invoke_harness(client, inv(idle_timeout: 300))
  end

  test "a frame split across chunk boundaries decodes without loss or duplication", %{
    bypass: bypass,
    client: client
  } do
    stop = frame(~s({"messageStop":{"stopReason":"end_turn"}}))
    start_frame = frame(~s({"messageStart":{"role":"assistant"}}))
    # Split the second frame mid-prelude.
    <<head::binary-size(5), tail::binary>> = stop

    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      chunked(conn, [start_frame, head, tail], 20)
    end)

    assert {:ok,
            [
              %{"messageStart" => %{"role" => "assistant"}},
              %{"messageStop" => %{"stopReason" => "end_turn"}}
            ]} = Client.invoke_harness(client, inv())
  end

  test "non-2xx responses still surface {:error, {:http_error, status, body}}", %{
    bypass: bypass,
    client: client
  } do
    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(429, ~s({"message":"Too many requests"}))
    end)

    assert {:error, {:http_error, 429, body}} = Client.invoke_harness(client, inv())
    assert body =~ "Too many requests"
  end
end
```

- [ ] **Step 3: Run the new tests to verify they fail**

Run: `mix test test/req_managed_agents/agent_core/client_stream_test.exs`
Expected: the "longer than idle_timeout" and "stalls beyond idle_timeout" tests FAIL against the buffered implementation (no `:idle_timeout` support — the first succeeds trivially only if buffering ignores gaps; the stall test must fail because today's 600s wall clock never fires at 300ms). If the FIRST test passes and the SECOND fails, that is the expected pre-implementation shape; what matters is both pass after Step 4 and the stall test proves the idle guard.

- [ ] **Step 4: Implement the streaming reducer**

In `lib/req_managed_agents/agent_core/client.ex`, add below `@default_receive_timeout`:

```elixir
  # Inter-chunk idle timeout for the streaming data plane (spec: MIM-50 design §3).
  @default_idle_timeout 300_000
```

Replace the body of `invoke_harness/2`'s `span(...)` fn — the `case request(...)` block — and keep everything above it (body/qs/url/json/headers construction) as-is except the `body` pipeline, which gains the three budget fields (Task 3 asserts them; adding now avoids touching this function twice):

```elixir
      body =
        %{"messages" => messages}
        |> maybe_put("model", inv[:model])
        |> maybe_put("systemPrompt", system_prompt_blocks(inv[:system_prompt]))
        |> maybe_put("timeoutSeconds", inv[:timeout_seconds])
        |> maybe_put("maxIterations", inv[:max_iterations])
        |> maybe_put("maxTokens", inv[:max_tokens])
```

and

```elixir
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
```

Add the private helpers at the bottom of the module (above `handle/1`):

```elixir
  # Streaming reducer for the invoke data plane: 2xx chunks decode incrementally
  # (firing on_event per decoded event, in order); non-2xx chunks accumulate raw
  # so the error tuple carries the body. With `into:` streaming, Finch applies
  # :receive_timeout per await — it is the inter-chunk idle guard, not a body cap.
  defp stream_reducer(on_event) do
    fn {:data, chunk}, {req, resp} ->
      resp =
        if resp.status in 200..299 do
          buffer = Map.get(resp.private, :rma_buffer, "") <> chunk
          {events, rest} = EventStream.decode(buffer)
          if on_event, do: Enum.each(events, on_event)

          resp
          |> Req.Response.put_private(:rma_events, Map.get(resp.private, :rma_events, []) ++ events)
          |> Req.Response.put_private(:rma_buffer, rest)
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
        events
    end
  end

  defp streamed_body(resp) do
    Map.get(resp.private, :rma_error_body) ||
      if(is_binary(resp.body), do: resp.body, else: "")
  end
```

Note: `decode_body: false` is no longer passed (with `into:` the reducer owns the body); do not re-add it.

- [ ] **Step 5: Run the new tests and the existing client tests**

Run: `mix test test/req_managed_agents/agent_core/client_stream_test.exs test/req_managed_agents/agent_core/client_test.exs`
Expected: ALL PASS — including the pre-existing `invoke_harness` tests (contract freeze) and the keep-alive test that injects a buffering `adapter:` (compat path). If the "longer than idle_timeout" test fails with a timeout here, the per-chunk assumption is disproven: STOP, do not work around it, report for the `Finch.stream/5` fallback decision.

- [ ] **Step 6: Run the full suite and commit**

Run: `mix format && mix test`
Expected: 0 failures.

```bash
jj describe -m 'feat(agent_core): stream InvokeHarness incrementally with inter-chunk idle timeout (MIM-50)' && jj new
```

---

### Task 2: `on_event` callback fires per decoded event, in order

**Files:**
- Modify: `test/req_managed_agents/agent_core/client_stream_test.exs` (append tests)
- Modify (only if Step 2 fails): `lib/req_managed_agents/agent_core/client.ex`

**Interfaces:**
- Consumes: Task 1's `stream_reducer/1` (already threads `inv[:on_event]`).
- Produces: `inv[:on_event] :: (map() -> any()) | nil` — called once per decoded event, in stream order, before `invoke_harness` returns. Task 4 relies on exactly this contract.

- [ ] **Step 1: Write the tests (append inside the module in `client_stream_test.exs`)**

```elixir
  test "on_event fires once per decoded event, in order, before invoke returns", %{
    bypass: bypass,
    client: client
  } do
    frames = [
      frame(~s({"messageStart":{"role":"assistant"}})),
      frame(~s({"contentBlockDelta":{"contentBlockIndex":0,"delta":{"text":"hello"}}})),
      frame(~s({"messageStop":{"stopReason":"end_turn"}}))
    ]

    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      chunked(conn, frames, 10)
    end)

    test_pid = self()

    assert {:ok, events} =
             Client.invoke_harness(
               client,
               inv(on_event: fn ev -> send(test_pid, {:ev, ev}) end)
             )

    # All on_event sends happened before invoke_harness returned -> already in our mailbox.
    received =
      for _ <- 1..3 do
        assert_received {:ev, ev}
        ev
      end

    assert received == events
    refute_received {:ev, _}
  end

  test "on_event is optional — omitting it changes nothing", %{bypass: bypass, client: client} do
    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      chunked(conn, [frame(~s({"messageStop":{"stopReason":"end_turn"}}))], 10)
    end)

    assert {:ok, [%{"messageStop" => _}]} = Client.invoke_harness(client, inv())
  end
```

- [ ] **Step 2: Run the tests**

Run: `mix test test/req_managed_agents/agent_core/client_stream_test.exs`
Expected: PASS (Task 1's reducer already implements this). If either fails, fix `stream_reducer/1` minimally until green — the contract is the test.

- [ ] **Step 3: Commit**

```bash
jj describe -m 'test(agent_core): on_event per-event ordering contract on the invoke stream (MIM-50)' && jj new
```

---

### Task 3: Budget knobs serialize onto the wire (and only when set)

**Files:**
- Modify: `test/req_managed_agents/agent_core/client_stream_test.exs` (append tests)
- Modify (only if needed): `lib/req_managed_agents/agent_core/client.ex`

**Interfaces:**
- Consumes: Task 1's body pipeline (`maybe_put` of the three fields is already in place).
- Produces: `inv[:timeout_seconds] | inv[:max_iterations] | inv[:max_tokens]` → body keys `"timeoutSeconds"` / `"maxIterations"` / `"maxTokens"`; absent when unset. Task 4 threads these from Session opts.

- [ ] **Step 1: Write the tests (append)**

```elixir
  test "budget knobs serialize as timeoutSeconds/maxIterations/maxTokens", %{
    bypass: bypass,
    client: client
  } do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})
      chunked(conn, [frame(~s({"messageStop":{"stopReason":"end_turn"}}))], 10)
    end)

    assert {:ok, _} =
             Client.invoke_harness(
               client,
               inv(timeout_seconds: 900, max_iterations: 40, max_tokens: 4096)
             )

    assert_received {:body, body}
    assert body["timeoutSeconds"] == 900
    assert body["maxIterations"] == 40
    assert body["maxTokens"] == 4096
  end

  test "budget knobs are absent from the body by default (harness defaults rule)", %{
    bypass: bypass,
    client: client
  } do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})
      chunked(conn, [frame(~s({"messageStop":{"stopReason":"end_turn"}}))], 10)
    end)

    assert {:ok, _} = Client.invoke_harness(client, inv())

    assert_received {:body, body}
    refute Map.has_key?(body, "timeoutSeconds")
    refute Map.has_key?(body, "maxIterations")
    refute Map.has_key?(body, "maxTokens")
  end
```

- [ ] **Step 2: Run the tests**

Run: `mix test test/req_managed_agents/agent_core/client_stream_test.exs`
Expected: PASS (Task 1 added the `maybe_put`s). Fix minimally if not.

- [ ] **Step 3: Commit**

```bash
jj describe -m 'test(agent_core): per-invocation server budget knobs on the wire (MIM-50)' && jj new
```

---

### Task 4: Provider threading — `BedrockAgentCore.open/2` captures the subscriber; invoke carries `on_event` + knobs

**Files:**
- Modify: `lib/req_managed_agents/providers/bedrock_agent_core.ex` (`open/2`, `invoke/3`, moduledoc)
- Test: `test/req_managed_agents/providers/bedrock_agent_core_test.exs` (append; the file exists — follow its existing `invoke_fun` injection style)

**Interfaces:**
- Consumes: Task 2's `inv[:on_event]` contract; Task 3's `inv[:timeout_seconds]`/`inv[:max_iterations]`/`inv[:max_tokens]`; `Session` calls `provider.open(opts, self())`.
- Produces: conn map gains `subscriber`, `idle_timeout`, `timeout_seconds`, `max_iterations`, `max_tokens`. Every `invoke_fun.(inv)` call receives those fields plus `on_event` which sends `{:provider_event, ev}` to `subscriber`. Task 5's Session clause consumes that message shape.

- [ ] **Step 1: Write the failing tests (append to `bedrock_agent_core_test.exs`)**

```elixir
  describe "MIM-50 long-run threading" do
    test "open/2 captures the subscriber and threads budgets; invoke carries on_event + knobs" do
      test_pid = self()

      invoke_fun = fn inv ->
        send(test_pid, {:inv, inv})
        # Exercise the on_event the provider built: it must message the subscriber.
        inv.on_event.(%{"messageStart" => %{"role" => "assistant"}})
        {:ok, [%{"messageStop" => %{"stopReason" => "end_turn"}}]}
      end

      {:ok, conn} =
        ReqManagedAgents.Providers.BedrockAgentCore.open(
          [
            harness_arn: "arn:aws:bedrock-agentcore:us-east-1:1:harness/ba",
            runtime_session_id: String.duplicate("s", 33),
            invoke_fun: invoke_fun,
            idle_timeout: 120_000,
            timeout_seconds: 900,
            max_iterations: 40,
            max_tokens: 4096
          ],
          self()
        )

      assert {:ok, _events, _conn} =
               ReqManagedAgents.Providers.BedrockAgentCore.poll_turn(conn, [
                 %{"role" => "user", "content" => [%{"text" => "hi"}]}
               ])

      assert_received {:inv, inv}
      assert inv.idle_timeout == 120_000
      assert inv.timeout_seconds == 900
      assert inv.max_iterations == 40
      assert inv.max_tokens == 4096
      assert is_function(inv.on_event, 1)
      # The on_event we invoked above delivered a live event to the subscriber (us).
      assert_received {:provider_event, %{"messageStart" => %{"role" => "assistant"}}}
    end

    test "budgets default to nil and on_event still targets the subscriber" do
      test_pid = self()

      invoke_fun = fn inv ->
        send(test_pid, {:inv, inv})
        {:ok, [%{"messageStop" => %{"stopReason" => "end_turn"}}]}
      end

      {:ok, conn} =
        ReqManagedAgents.Providers.BedrockAgentCore.open(
          [
            harness_arn: "arn:aws:bedrock-agentcore:us-east-1:1:harness/ba",
            runtime_session_id: String.duplicate("s", 33),
            invoke_fun: invoke_fun
          ],
          self()
        )

      assert {:ok, _events, _conn} =
               ReqManagedAgents.Providers.BedrockAgentCore.poll_turn(conn, [
                 %{"role" => "user", "content" => [%{"text" => "hi"}]}
               ])

      assert_received {:inv, inv}
      assert inv.idle_timeout == nil
      assert inv.timeout_seconds == nil
      assert inv.max_iterations == nil
      assert inv.max_tokens == nil
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/req_managed_agents/providers/bedrock_agent_core_test.exs`
Expected: FAIL — `inv` has no `:on_event`/`:idle_timeout`/budget keys (KeyError or match failure).

- [ ] **Step 3: Implement the threading**

In `lib/req_managed_agents/providers/bedrock_agent_core.ex`, replace `open/2` and the `inv` construction in `invoke/3`:

```elixir
  @impl true
  def open(opts, subscriber) do
    {:ok,
     %{
       harness_arn: Keyword.fetch!(opts, :harness_arn),
       sid: Keyword.fetch!(opts, :runtime_session_id),
       model: opts[:model],
       retries: opts[:invoke_retries] || 2,
       subscriber: subscriber,
       idle_timeout: opts[:idle_timeout],
       timeout_seconds: opts[:timeout_seconds],
       max_iterations: opts[:max_iterations],
       max_tokens: opts[:max_tokens],
       # Build the real client (which reads AWS creds) ONLY when no invoke_fun is injected.
       invoke_fun: opts[:invoke_fun] || default_invoke_fun(opts)
     }}
  end
```

and in `invoke/3`:

```elixir
    inv = %{
      harness_arn: conn.harness_arn,
      runtime_session_id: conn.sid,
      messages: messages,
      model: conn.model,
      idle_timeout: conn.idle_timeout,
      timeout_seconds: conn.timeout_seconds,
      max_iterations: conn.max_iterations,
      max_tokens: conn.max_tokens,
      on_event: live_forward(conn.subscriber)
    }
```

with one new private helper:

```elixir
  # Live event delivery: each decoded event is sent to the Session (the open/2
  # subscriber) as it arrives. Ordering vs the final {:turn, result} is guaranteed
  # because both originate in the same poll-turn task (FIFO per sender).
  defp live_forward(subscriber) when is_pid(subscriber),
    do: fn ev -> send(subscriber, {:provider_event, ev}) end

  defp live_forward(_), do: nil
```

Also update the moduledoc's last sentence to mention live delivery, e.g. append: `Decoded events are additionally delivered live to the session as {:provider_event, ev} messages while a turn streams.`

- [ ] **Step 4: Run the provider tests, then the full suite**

Run: `mix test test/req_managed_agents/providers/bedrock_agent_core_test.exs && mix test`
Expected: ALL PASS. (Existing provider tests pass a subscriber of `self()` already via `open(opts, self())` call sites or nil-tolerant paths; if an existing test calls `open(opts, nil)`, `live_forward(nil)` returns nil and nothing changes.)

- [ ] **Step 5: Commit**

```bash
jj describe -m 'feat(provider): BedrockAgentCore threads subscriber/on_event + server budgets into the invoke (MIM-50)' && jj new
```

---

### Task 5: Session live delivery — `{:provider_event, ev}` clause + skip-batch rule

**Files:**
- Modify: `lib/req_managed_agents/session.ex` (init state map, one new `handle_info` clause, the `{:turn, {:ok, …}}` clause)
- Test: `test/req_managed_agents/session_live_events_test.exs` (new file)

**Interfaces:**
- Consumes: Task 4's `{:provider_event, ev}` message shape; existing `forward_raw/2`; existing `[:req_managed_agents, :stream, :event]` telemetry event name (the Claude path's).
- Produces: handler sees each turn event exactly once per attempt (live when the provider streams, batch otherwise); `SessionResult.events` unchanged (canonical, successful attempt only).

- [ ] **Step 1: Write the failing tests**

```elixir
# test/req_managed_agents/session_live_events_test.exs
defmodule ReqManagedAgents.SessionLiveEventsTest do
  use ExUnit.Case, async: true

  # request_response provider that delivers events LIVE (like BedrockAgentCore
  # post-MIM-50): poll_turn sends {:provider_event, ev} to the subscriber
  # captured at open, then returns the same events as the turn result.
  defmodule LiveRR do
    @behaviour ReqManagedAgents.Provider
    alias ReqManagedAgents.{ToolUse, TurnResult}

    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, subscriber), do: {:ok, %{subscriber: subscriber, opts: opts}}
    @impl true
    def kickoff_input(_opts), do: [:kickoff]
    @impl true
    def user_input(text), do: [{:user, text}]
    @impl true
    def resume_input(_uses, _results), do: [:resume]

    @impl true
    def poll_turn(conn, _input) do
      events = [
        %{"messageStart" => %{"role" => "assistant"}},
        %{"messageStop" => %{"stopReason" => "end_turn"}}
      ]

      Enum.each(events, &send(conn.subscriber, {:provider_event, &1}))
      {:ok, events, conn}
    end

    @impl true
    def normalize(events) do
      %TurnResult{
        terminal: :end_turn,
        stop_reason: "end_turn",
        text: "",
        custom_tool_uses: [],
        server_tool_uses: [],
        usage: nil,
        events: events
      }
    end
  end

  # Same provider WITHOUT live delivery — the batch path must keep working.
  defmodule BatchRR do
    @behaviour ReqManagedAgents.Provider
    alias ReqManagedAgents.TurnResult

    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, subscriber), do: {:ok, %{subscriber: subscriber, opts: opts}}
    @impl true
    def kickoff_input(_opts), do: [:kickoff]
    @impl true
    def user_input(text), do: [{:user, text}]
    @impl true
    def resume_input(_uses, _results), do: [:resume]

    @impl true
    def poll_turn(conn, _input) do
      {:ok,
       [
         %{"messageStart" => %{"role" => "assistant"}},
         %{"messageStop" => %{"stopReason" => "end_turn"}}
       ], conn}
    end

    @impl true
    def normalize(events) do
      %TurnResult{
        terminal: :end_turn,
        stop_reason: "end_turn",
        text: "",
        custom_tool_uses: [],
        server_tool_uses: [],
        usage: nil,
        events: events
      }
    end
  end

  defmodule CountingHandler do
    @behaviour ReqManagedAgents.Handler

    @impl true
    def handle_tool_call(_name, _input, _ctx), do: {:ok, "unused"}

    @impl true
    def handle_event(ev, %{test_pid: pid}) do
      send(pid, {:handler_saw, ev})
      :ok
    end
  end

  test "live provider: handler sees each event exactly once (no batch double-delivery)" do
    assert {:ok, result} =
             ReqManagedAgents.Session.run(LiveRR,
               handler: CountingHandler,
               context: %{test_pid: self()},
               prompt: "go"
             )

    assert result.terminal == :end_turn
    assert_received {:handler_saw, %{"messageStart" => _}}
    assert_received {:handler_saw, %{"messageStop" => _}}
    refute_received {:handler_saw, _}
    # Canonical record still carries the turn's events.
    assert length(result.events) == 2
  end

  test "batch provider: handler still sees events exactly once via batch delivery" do
    assert {:ok, result} =
             ReqManagedAgents.Session.run(BatchRR,
               handler: CountingHandler,
               context: %{test_pid: self()},
               prompt: "go"
             )

    assert result.terminal == :end_turn
    assert_received {:handler_saw, %{"messageStart" => _}}
    assert_received {:handler_saw, %{"messageStop" => _}}
    refute_received {:handler_saw, _}
  end

  test "live events emit [:req_managed_agents, :stream, :event] telemetry with the envelope type" do
    test_pid = self()
    handler_id = "live-events-telemetry-#{inspect(self())}"

    :telemetry.attach(
      handler_id,
      [:req_managed_agents, :stream, :event],
      fn _event, _meas, meta, _cfg -> send(test_pid, {:stream_event_meta, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _} =
             ReqManagedAgents.Session.run(LiveRR,
               handler: CountingHandler,
               context: %{test_pid: self()},
               prompt: "go",
               telemetry_metadata: %{mim: 50}
             )

    assert_received {:stream_event_meta, %{type: "messageStart", mim: 50}}
    assert_received {:stream_event_meta, %{type: "messageStop", mim: 50}}
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/req_managed_agents/session_live_events_test.exs`
Expected: FAIL — the first test sees each event TWICE (live path unhandled → `handle_info(_other, s)` drops them today, so actually: the live test fails on missing `handler_saw` before batch delivers... run and read carefully). The pre-fix behavior: `{:provider_event, …}` hits the catch-all `handle_info(_other, s)` (dropped), then batch delivery forwards each event once — so the FIRST test passes spuriously except telemetry, and the THIRD test fails (no telemetry). That is the red anchor. After implementation all three must pass with the live path doing the forwarding.

- [ ] **Step 3: Implement**

In `lib/req_managed_agents/session.ex`:

1. Add `live_forwarded: 0` to the state map in `init/1` (after `turn_events: [],`).

2. Add the new clause immediately ABOVE `def handle_info({:turn, {:ok, events, conn}}, s) do`:

```elixir
  # Live event from a request_response provider mid-turn (e.g. BedrockAgentCore
  # streaming): forward to the handler and telemetry NOW; the {:turn, …} that
  # follows (FIFO from the same poll-turn task) then skips batch forwarding.
  # Handler delivery is at-least-once across retried attempts — the canonical
  # exactly-once record is TurnResult/SessionResult.events.
  def handle_info({:provider_event, ev}, s) do
    forward_raw(s, ev)

    :telemetry.execute(
      [:req_managed_agents, :stream, :event],
      %{},
      Map.merge(s.meta, %{type: envelope_type(ev)})
    )

    {:noreply, %{s | live_forwarded: s.live_forwarded + 1}}
  end
```

3. Replace the `{:turn, {:ok, …}}` clause:

```elixir
  def handle_info({:turn, {:ok, events, conn}}, s) do
    # Batch forwarding only when nothing was live-forwarded this turn (a live
    # provider already delivered each event as it arrived).
    if s.live_forwarded == 0, do: Enum.each(events, &forward_raw(s, &1))
    handle_turn(%{s | conn: conn, live_forwarded: 0}, events)
  end
```

4. Add the private helper next to `forward_raw/2`:

```elixir
  # A Converse-envelope event is a single-key map (%{"messageStop" => …}).
  defp envelope_type(%{} = ev), do: ev |> Map.keys() |> List.first()
```

- [ ] **Step 4: Run the new tests, then the full suite**

Run: `mix test test/req_managed_agents/session_live_events_test.exs && mix test`
Expected: ALL PASS — including every existing Session/provider/integration test (the batch path is behavior-identical when no live events arrive).

- [ ] **Step 5: Commit**

```bash
jj describe -m 'feat(session): live per-event handler/telemetry delivery with skip-batch rule (MIM-50)' && jj new
```

---

### Task 6: Docs + CHANGELOG

**Files:**
- Modify: `lib/req_managed_agents/handler.ex` (moduledoc), `lib/req_managed_agents/session.ex` (moduledoc), `lib/req_managed_agents/agent_core/client.ex` (moduledoc), `lib/req_managed_agents/providers/bedrock_agent_core.ex` (verify Task 4's moduledoc line), `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: everything shipped in Tasks 1–5.
- Produces: user-facing documentation of the long-run posture. No code changes.

- [ ] **Step 1: Handler moduledoc — at-least-once note**

Append to the `@moduledoc` of `lib/req_managed_agents/handler.ex` (read the file first; keep its voice):

```markdown
  `handle_event/2` is observational and **at-least-once**: on reconnect (Claude) or a
  retried turn (Bedrock AgentCore), events from an aborted attempt may be delivered
  before the successful attempt's. The canonical exactly-once record is
  `ReqManagedAgents.SessionResult.events`.
```

- [ ] **Step 2: Session moduledoc — timeout interplay**

In `lib/req_managed_agents/session.ex` `@moduledoc`, extend the "Optional:" line's paragraph with:

```markdown
  For long AgentCore runs set `:timeout` (the end-to-end run budget, default 600_000 ms)
  at or above the server-side budget; transport liveness is guarded per turn by
  `:idle_timeout` and total cost by the `:timeout_seconds`/`:max_iterations`/`:max_tokens`
  per-invocation overrides (Bedrock AgentCore only).
```

- [ ] **Step 3: Client moduledoc — data-plane timeout semantics**

Append to `lib/req_managed_agents/agent_core/client.ex` `@moduledoc`:

```markdown
  The invoke data plane streams incrementally: `receive_timeout` on this struct governs
  control-plane calls only, while `invoke_harness/2` uses the per-invoke `:idle_timeout`
  (default 300_000 ms) as an inter-chunk liveness guard — a healthy turn may run
  arbitrarily long; only silence fails it.
```

- [ ] **Step 4: README — budgets + live events (Bedrock pattern section)**

In `README.md`, in "The Bedrock AgentCore pattern (setup)" step 2, after the sentence about resume, add:

```markdown
   Long runs: pass `idle_timeout:` (inter-chunk liveness guard, default 300s — the turn
   itself has **no client wall clock**) and the server budgets `timeout_seconds:`,
   `max_iterations:`, `max_tokens:` (per-invocation overrides of the harness defaults).
   Events stream to your `Handler.handle_event/2` live as the turn runs.
```

- [ ] **Step 5: CHANGELOG — Unreleased section**

At the top of `CHANGELOG.md` (below the header, above `## [0.1.0]`):

```markdown
## [Unreleased]

### Changed
- Bedrock AgentCore `InvokeHarness` now streams incrementally: turns are guarded by an
  inter-chunk `idle_timeout` (default 300s) instead of a 10-minute whole-body wall clock,
  so long-running turns complete while dead connections fail fast (MIM-50 posture).
- `Handler.handle_event/2` fires live during AgentCore turns (previously only after the
  turn completed) and is documented as at-least-once across retried attempts.

### Added
- Per-invocation AgentCore server budgets on `Session.run/2` opts: `timeout_seconds`,
  `max_iterations`, `max_tokens` (wire: `timeoutSeconds`/`maxIterations`/`maxTokens`).
- `idle_timeout` opt on the AgentCore invoke path.
- `[:req_managed_agents, :stream, :event]` telemetry now also fires for AgentCore turns.
```

Note: CHANGELOG.md currently has no `[Unreleased]` section and MIM-refs are acceptable in CHANGELOG only as the "(MIM-50 posture)" parenthetical above — drop it if the reviewer objects; docs/ and CHANGELOG are shipped in the tarball, so keep the text self-explanatory either way.

- [ ] **Step 6: Docs build + full suite, commit**

Run: `MIX_ENV=dev mix docs --warnings-as-errors && mix format && mix test`
Expected: docs build clean (no broken refs), 0 test failures.

```bash
jj describe -m 'docs: long-run posture — idle timeout, server budgets, at-least-once handle_event' && jj new
```

---

### Task 7: QA sweep + live canary extension

**Files:**
- Modify: `test/live/live_smoke_test.exs` (the Bedrock AgentCore live test)

**Interfaces:**
- Consumes: Tasks 1–6 complete.
- Produces: green offline gate (format/credo/dialyzer/docs/suite) and a canary that exercises the new knobs on real AWS (runs Mon+Thu in CI; do NOT run live tests in this task — no creds in the dev loop).

- [ ] **Step 1: Extend the live smoke**

Read `test/live/live_smoke_test.exs`, find the AgentCore `Session.run(BedrockAgentCore, …)` (or `invoke_to_completion`) call, and add to its opts:

```elixir
        # MIM-50: exercise the per-invocation server budgets + a generous idle guard
        # against a real harness — validates the overrides are accepted on the wire
        # and that the 300s idle floor holds during server-side tool execution.
        idle_timeout: 300_000,
        timeout_seconds: 900,
        max_iterations: 40,
```

(Adjust placement to the file's existing opts style; keep env-overridable values as they are.)

- [ ] **Step 2: Full offline QA gate**

Run each, expect success:

```bash
mix format --check-formatted
mix test                       # 0 failures (live excluded by default)
mix credo --strict
MIX_ENV=dev mix docs --warnings-as-errors
mix dialyzer                   # PLTs cached in priv/plts; first run is slow
mix hex.build                  # tarball still builds (files list unchanged)
```

- [ ] **Step 3: Commit**

```bash
jj describe -m 'test(live): canary exercises MIM-50 budgets + idle guard on real AgentCore' && jj new
```

---

## Execution notes for the coordinator

- Workspace: all tasks run in the existing jj workspace `.claude/worktrees/rma-ci-pipeline/` (already positioned on main with the spec + this plan committed on top).
- After Task 7: push a bookmark `ryan/mim-50-agentcore-long-run-posture` (Linear's suggested branch prefix) and open the PR titled `MIM-50: feat(agent_core): streaming liveness long-run posture` with `Closes MIM-50` as the last plain-text line of the body (linear-pr-conventions).
- The live canary (workflow dispatch) is the final validation after merge — coordinate with the user before dispatching (AWS spend).
