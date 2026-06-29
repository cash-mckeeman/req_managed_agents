# AgentCore Harness Streaming Hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a single `InvokeHarness` turn survive long server-side work and surface (rather than silently swallow) early server-side terminations, without leaving the managed Harness or adopting polling.

**Architecture:** All changes are in the `req_managed_agents` client lib. A live diagnostic spike (Task 1) classifies the recurring fast early-termination (`case_03`/`case_04`); the fix is **re-aligning our event-stream decoder to canonical `agentjido/req_llm`** — replacing our silent-drop with `{:error, reason}` returns — **and adding `:message-type` exception/error surfacing** the decoder (and upstream) currently lacks (Task 2; also an upstream PR candidate, MIM-51). The per-turn loop then gets a distinct error surface for persistent early-termination vs transient drop (Task 3). SigV4 moves to `ex_aws_auth` (Task 7, independent). Keep-alive + a configurable receive-timeout default (Task 4) and a session MaxLifetime cost guardrail (Task 5) are independent hardening. A live eval-gate checkpoint validates (Task 6).

**Wire-boundary note:** see the spec's "Wire-boundary cleanup" section. We re-align to canonical req_llm (not depend on it / not extract yet — extraction is MIM-43). Verify the reference against `agentjido/req_llm` **origin**, not the `cash-mckeeman` fork.

**Tech Stack:** Elixir, Req/Finch/Mint (HTTP), `vnd.amazon.eventstream` binary framing, ExUnit + Bypass + `invoke_fun` seams.

**Spec:** `docs/superpowers/specs/2026-06-28-agentcore-streaming-hardening-design.md`

---

## File Structure

- `lib/req_managed_agents/agent_core/event_stream.ex` — **modify.** Re-align to canonical `agentjido/req_llm` `AWSEventStream`: return `{:error, reason}` on undecodable frames instead of silently dropping, and add `:message-type` `exception`/`error` surfacing as a tagged map. (Tasks 1, 2)
- `lib/req_managed_agents/agent_core/sig_v4.ex` — **delete** (Task 7); replace its call site with `ex_aws_auth`.
- `mix.exs` — **modify.** Promote `:ex_aws_auth` from `optional: true` to a regular dep (Task 7).
- `lib/req_managed_agents/agent_core.ex` — **modify.** `invoke_turn`/`loop` gain a distinct error surface for a *persistent* early-termination (recurs through retry) vs a *transient* drop (retry resolves). (Task 3)
- `lib/req_managed_agents/agent_core/client.ex` — **modify.** `request/6` gains keep-alive transport options; `receive_timeout` default becomes a named module attribute; `create_harness` passes a configurable `maxLifetime`. (Tasks 4, 5)
- `test/req_managed_agents/agent_core/event_stream_test.exs` — **modify.** (Tasks 2)
- `test/req_managed_agents/agent_core_test.exs` — **modify.** (Task 3)
- `test/req_managed_agents/agent_core/client_test.exs` — **modify.** (Tasks 4, 5)
- `docs/superpowers/specs/2026-06-28-agentcore-streaming-hardening-design.md` — **append** Task 1 findings.

---

### Task 1: [SPIKE — LIVE AWS] Classify the case_03/case_04 early termination

**This is a diagnostic spike, not a TDD task.** It requires live AWS + the app's harness path and is run interactively (like a QA-CHECKPOINT), not by an offline subagent. It **gates Tasks 2–3** — its finding confirms or redirects their implementation. No production code is committed in this task; output is written findings.

**Files:**
- Append findings to: `docs/superpowers/specs/2026-06-28-agentcore-streaming-hardening-design.md` (a `## Task 1 findings` section)

- [ ] **Step 1: Add a temporary raw-frame dump to the decoder (throwaway).**

In `lib/req_managed_agents/agent_core/event_stream.ex`, inside `decode_loop/2` right after `headers = parse_headers(headers_bin)`, temporarily add:

```elixir
IO.inspect({headers[":message-type"], headers[":event-type"], headers[":exception-type"], byte_size(body)},
  label: "AGENTCORE_FRAME")
```

This prints every frame's `:message-type` / `:event-type` / `:exception-type` headers + body size as they arrive. **Revert this before Task 2.**

- [ ] **Step 2: Drive one failing case live and capture frames.**

From the app worktree (`biai-managed-agents/.claude/worktrees/mim39-p2b-app/elixir`), with `.env` + AWS creds exported and the client pinned to a local path or this branch, run a single early-terminating case (case_03 or case_04) through the harness — e.g. via the eval gate filtered to one case, or an `iex` `Agent.narrate/2`. Capture stdout.

Run: `EVAL_EMBEDDER=voyage BUSINESS_ANALYST_RUNTIME=agentcore_harness BUSINESS_ANALYST_MODEL=bedrock:us.anthropic.claude-sonnet-4-5-20250929-v1:0 HARNESS_EXECUTION_ROLE_ARN=arn:aws:iam::819613816573:role/AgentCoreHarnessExecRole-p2b EVAL_CASE_LIMIT=3 mix test test/managed_agents/business_analyst/parity/eval_parity_test.exs --only external`
Expected: `AGENTCORE_FRAME` lines; the last frames before the turn ends are the diagnostic payload.

- [ ] **Step 3: Classify and record the finding.**

Determine which the trailing frames show:
- **`:message-type` = `exception` or `error`** (with an `:exception-type` / `:error-code`) → server-side early close. Task 2 surfaces it. **Most likely.**
- **A Jason-undecodable body** (decoder's silent-drop path) → Task 2's tagging + a decode-failure surface covers it.
- **A clean `messageStop` our parser misreads** → adjust `Converse.parse`/`terminal_atom` instead; note the variant.
- **Steady frames then a hard socket close mid-body** (no terminal frame) → genuine transport; Task 4 keep-alive is the lever and Task 3's persistent-vs-transient split is the surface.

Write a `## Task 1 findings` section to the spec: the captured trailing frames (headers + sizes), the classification, and which of Tasks 2–4 it confirms.

- [ ] **Step 4: Revert the throwaway dump.**

Remove the `IO.inspect` from Step 1. Confirm `git diff lib/` is empty.
Run: `cd /Users/ryanmckeeman/src/bizinsights/req_managed_agents/.claude/worktrees/mim50-spec && jj diff --git lib/`
Expected: no output (clean).

- [ ] **Step 5: Commit the findings.**

```bash
jj describe @ -m "docs(spec): Task 1 spike findings — case_03/04 early-termination frame classification (MIM-50)"
jj bookmark set ryan/mim50-spec -r @
jj new
```

---

### Task 2: Re-align decoder to canonical + surface AWS exception/error frames

**Context:** The AWS `vnd.amazon.eventstream` framing tags each message with a `:message-type` header: `event` (normal), `exception` (modeled error), or `error` (transport/internal error). Two problems, both confirmed against **canonical `agentjido/req_llm` `AWSEventStream`** (origin, not the fork):
1. **Our port drifted:** canonical returns `{:error, reason}` on an undecodable body; **ours silently drops it** (`{:error, _} -> acc`). We re-align by surfacing rather than dropping.
2. **A gap in canonical too:** neither tags `:message-type` `exception`/`error` frames — both return a non-`:event-type` body as a raw map, so an early-termination exception becomes shapeless → `stop_reason: nil`. We surface it as a tagged map; this is also the **upstream PR candidate MIM-51**.

We keep our intentional `{events, remainder}` chunked return shape (incremental decoding) — alignment is about *error visibility*, not adopting canonical's `{:ok, events}` signature. Confirm the exact `:message-type`/`:exception-type` headers against Task 1's captured frames; the values below are the AWS event-stream standard.

**Files:**
- Modify: `lib/req_managed_agents/agent_core/event_stream.ex`
- Test: `test/req_managed_agents/agent_core/event_stream_test.exs`

- [ ] **Step 1: Write the failing test for an exception frame.**

Add to `test/req_managed_agents/agent_core/event_stream_test.exs`. This builds a real event-stream frame with `:message-type` = `exception` using the file's existing frame-builder helper (mirror how the existing tests construct frames — reuse that helper; if the test file lacks one, the existing passing tests show the byte layout to copy).

```elixir
test "an exception frame is surfaced as a tagged map, not dropped" do
  # :message-type = "exception", :exception-type = "ThrottlingException"
  frame =
    build_frame(
      [{":message-type", "exception"}, {":exception-type", "ThrottlingException"}],
      ~s({"message":"Rate exceeded"})
    )

  assert {[event], <<>>} = EventStream.decode(frame)
  assert %{"__stream_error__" => %{"type" => "ThrottlingException", "message" => %{"message" => "Rate exceeded"}}} = event
end
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `mix test test/req_managed_agents/agent_core/event_stream_test.exs -k "exception frame"`
Expected: FAIL — the frame is currently passed through untagged (no `__stream_error__` key) or dropped.

- [ ] **Step 3: Implement exception/error tagging in `decode_loop/2`.**

In `lib/req_managed_agents/agent_core/event_stream.ex`, in the `case Jason.decode(body)` block where the event is currently built, branch on `:message-type` **before** the `:event-type` logic. Replace the existing `{:ok, map} -> ...` body with:

```elixir
{:ok, map} ->
  wrapped =
    case headers[":message-type"] do
      mt when mt in ["exception", "error"] ->
        %{"__stream_error__" => %{"type" => headers[":exception-type"] || headers[":error-code"], "message" => map}}

      _ ->
        case headers[":event-type"] do
          nil -> map
          event_type -> %{event_type => map}
        end
    end

  [wrapped | acc]
```

Also change the silent-drop arm so an **undecodable** exception/error body still surfaces (a raw string), instead of vanishing:

```elixir
{:error, _} ->
  case headers[":message-type"] do
    mt when mt in ["exception", "error"] ->
      [%{"__stream_error__" => %{"type" => headers[":exception-type"] || headers[":error-code"], "message" => body}} | acc]

    _ ->
      acc
  end
```

- [ ] **Step 4: Run the test to verify it passes.**

Run: `mix test test/req_managed_agents/agent_core/event_stream_test.exs`
Expected: PASS (new test + all existing decode tests still green).

- [ ] **Step 5: Commit.**

```bash
jj describe @ -m "feat(event_stream): surface AWS exception/error frames as __stream_error__ (no silent drop) — MIM-50"
jj bookmark set ryan/mim50-spec -r @
jj new
```

---

### Task 3: Distinct error surface for persistent early-termination vs transient drop

**Context:** `invoke_to_completion`'s `invoke_turn/3` retries when `stop_reason == nil`, and on exhaustion returns the still-truncated result as `{:ok, events, parsed}` → `handle/3` maps it to `{:ok, %{terminal: :terminated, stop_reason: nil}}`. Two problems: (a) a stream that carries a `__stream_error__` frame (Task 2) should surface as a real error, not `:terminated`; (b) a truncation that **survives the retry** (case_03/04) must be a distinct, diagnosable error, not swallowed as a soft terminal. This implements the spec's failure taxonomy.

**Files:**
- Modify: `lib/req_managed_agents/agent_core.ex`
- Test: `test/req_managed_agents/agent_core_test.exs`

- [ ] **Step 1: Write the failing test — a `__stream_error__` frame surfaces as `{:error, ...}`.**

Add to `test/req_managed_agents/agent_core_test.exs`:

```elixir
test "a stream-error frame surfaces as {:error, {:harness_stream_error, ...}}, not a soft terminal" do
  invoke_fun = fn _ ->
    {:ok, [%{"__stream_error__" => %{"type" => "InternalServerException", "message" => "boom"}}]}
  end

  assert {:error, {:harness_stream_error, "InternalServerException", "boom"}} =
           AgentCore.invoke_to_completion(
             handler: fn _, _, _ -> {:ok, ""} end,
             context: %{},
             harness_arn: "ba",
             runtime_session_id: "s1",
             prompt: "begin",
             invoke_fun: invoke_fun
           )
end
```

- [ ] **Step 2: Write the failing test — a persistent truncation surfaces as `{:error, :early_termination}`.**

```elixir
test "a truncation that survives the retry surfaces as {:error, :early_termination}, not :terminated/nil" do
  # Always truncated: a text delta, never a messageStop.
  invoke_fun = fn _ ->
    {:ok, [%{"contentBlockDelta" => %{"contentBlockIndex" => 0, "delta" => %{"text" => "x"}}}]}
  end

  assert {:error, :early_termination} =
           AgentCore.invoke_to_completion(
             handler: fn _, _, _ -> {:ok, ""} end,
             context: %{},
             harness_arn: "ba",
             runtime_session_id: "s1",
             prompt: "begin",
             invoke_fun: invoke_fun,
             invoke_retries: 1
           )
end
```

- [ ] **Step 3: Run both tests to verify they fail.**

Run: `mix test test/req_managed_agents/agent_core_test.exs -k "stream-error frame or survives the retry"`
Expected: FAIL — currently the first returns `{:ok, %{terminal: :terminated}}` (or crashes on parse) and the second returns `{:ok, %{terminal: :terminated, stop_reason: nil}}`.

- [ ] **Step 4: Detect `__stream_error__` in `invoke_turn/3`.**

In `lib/req_managed_agents/agent_core.ex`, in `invoke_turn/3`, after `parsed = Converse.parse(events)` is unavailable for this (it's a raw frame), check the raw events first. Replace the `{:ok, events} ->` arm of `invoke_turn/3` with:

```elixir
{:ok, events} ->
  case stream_error(events) do
    {type, message} ->
      {:error, {:harness_stream_error, type, message}}

    nil ->
      parsed = Converse.parse(events)

      cond do
        parsed.stop_reason != nil -> {:ok, events, parsed}
        retries_left > 0 -> invoke_turn(state, inv, retries_left - 1)
        true -> {:early_termination, events, parsed}
      end
  end
```

Add the helper (private, near `invoke_turn/3`):

```elixir
# A surfaced AWS exception/error frame (EventStream tags it __stream_error__).
defp stream_error(events) do
  Enum.find_value(events, fn
    %{"__stream_error__" => %{"type" => t, "message" => m}} -> {t, m}
    _ -> nil
  end)
end
```

- [ ] **Step 5: Handle the new `:early_termination` and error returns in `loop/3`.**

In `loop/3`, the `case invoke_turn(...)` currently has `{:ok, events, parsed}` and `{:error, reason}`. Add the early-termination arm:

```elixir
case invoke_turn(state, inv, state.invoke_retries) do
  {:ok, events, parsed} ->
    state = %{state | events: state.events ++ events}
    handle(state, parsed, deadline)

  {:early_termination, _events, _parsed} ->
    {:error, :early_termination}

  {:error, reason} ->
    {:error, reason}
end
```

- [ ] **Step 6: Run the tests to verify they pass.**

Run: `mix test test/req_managed_agents/agent_core_test.exs`
Expected: PASS — both new tests, plus the existing retry tests (transport-then-success, truncated-then-success, exhausts-retries) still green. Note the exhaust-retries-transport test still returns `{:error, %Req.TransportError{}}` (a transport error, unchanged); only the truncation-exhaust path now returns `:early_termination`.

- [ ] **Step 7: Commit.**

```bash
jj describe @ -m "feat(agent_core): distinct error surface — :harness_stream_error + :early_termination (taxonomy) — MIM-50"
jj bookmark set ryan/mim50-spec -r @
jj new
```

---

### Task 4: TCP keep-alive + named receive-timeout default

**Context (spec Component 2):** keep the per-turn socket warm during silent server-side stretches and stop hardcoding `600_000`. Keep-alive cannot manufacture server heartbeats (see spec caveat) but defends against transport-level idle drops. `request/6` builds the `Req` options; keep-alive goes via `connect_options: [transport_opts: [keepalive: true]]` (Req → Finch → Mint → `:gen_tcp`).

**Files:**
- Modify: `lib/req_managed_agents/agent_core/client.ex`
- Test: `test/req_managed_agents/agent_core/client_test.exs`

- [ ] **Step 1: Write the failing test — the invoke request carries keep-alive.**

The cleanest offline assertion uses a `Req` test plug to capture the merged options. Add to `client_test.exs`:

```elixir
test "invoke requests enable TCP keep-alive via connect_options" do
  test_pid = self()

  client =
    Client.new(
      credentials: @creds,
      req_options: [
        adapter: fn req ->
          send(test_pid, {:connect_options, req.options[:connect_options]})
          {req, Req.Response.new(status: 200, body: "")}
        end
      ]
    )

  Client.invoke_harness(client, %{
    harness_arn: "arn:aws:bedrock-agentcore:us-east-1:1:harness/ba",
    runtime_session_id: String.duplicate("s", 33),
    messages: [%{"role" => "user", "content" => [%{"text" => "hi"}]}]
  })

  assert_receive {:connect_options, opts}
  assert get_in(opts, [:transport_opts, :keepalive]) == true
end
```

- [ ] **Step 2: Run it to verify it fails.**

Run: `mix test test/req_managed_agents/agent_core/client_test.exs -k "keep-alive"`
Expected: FAIL — `connect_options` is currently `nil`.

- [ ] **Step 3: Add keep-alive + named default to `client.ex`.**

Add the module attribute near `@max_retries`:

```elixir
@default_receive_timeout 600_000
```

Replace the two literal `600_000` defaults in `defstruct` and `new/1` with `@default_receive_timeout`. Then in `request/6`, add `connect_options`:

```elixir
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
```

- [ ] **Step 4: Run the test to verify it passes.**

Run: `mix test test/req_managed_agents/agent_core/client_test.exs`
Expected: PASS (new test + all existing client tests green).

- [ ] **Step 5: Commit.**

```bash
jj describe @ -m "feat(agent_core/client): TCP keep-alive on requests + named receive-timeout default — MIM-50"
jj bookmark set ryan/mim50-spec -r @
jj new
```

---

### Task 5: Cost guardrail — configurable harness MaxLifetime

**Context (spec Component 4 + finding):** harnesses carry a `maxLifetime` (observed default 3600s in live `get-harness`). Make it an explicit, configurable field on `create_harness` so an abandoned session self-expires on a known, tunable bound rather than an implicit default. (Confirm the wire field name against the `CreateHarness` botocore model — `maxLifetime` per the observed `get-harness` output; if the create input names it differently, use that name and note it.)

**Files:**
- Modify: `lib/req_managed_agents/agent_core/client.ex`
- Test: `test/req_managed_agents/agent_core/client_test.exs`

- [ ] **Step 1: Write the failing test — `create_harness` sends `maxLifetime` when the spec provides it.**

Add to `client_test.exs`:

```elixir
test "create_harness includes maxLifetime when provided" do
  Bypass.expect_once(bypass, "POST", "/harnesses", fn conn ->
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    assert Jason.decode!(body)["maxLifetime"] == 1800

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, ~s({"harness":{"arn":"a","harnessId":"h","status":"CREATING"}}))
  end)

  spec = %{
    name: "ba",
    execution_role_arn: "arn:aws:iam::1:role/x",
    system_prompt: "p",
    tools: [],
    model: %{"bedrockModelConfig" => %{"modelId" => "m"}},
    max_lifetime: 1800
  }

  assert {:ok, _} = Client.create_harness(client, spec)
end
```

- [ ] **Step 2: Write the failing test — `maxLifetime` is omitted when absent.**

```elixir
test "create_harness omits maxLifetime when the spec does not set it" do
  Bypass.expect_once(bypass, "POST", "/harnesses", fn conn ->
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    refute Map.has_key?(Jason.decode!(body), "maxLifetime")

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, ~s({"harness":{"arn":"a","harnessId":"h","status":"CREATING"}}))
  end)

  spec = %{name: "ba", execution_role_arn: "r", system_prompt: "p", tools: [], model: %{}}
  assert {:ok, _} = Client.create_harness(client, spec)
end
```

- [ ] **Step 3: Run both to verify they fail.**

Run: `mix test test/req_managed_agents/agent_core/client_test.exs -k "maxLifetime"`
Expected: FAIL — the body never includes `maxLifetime`.

- [ ] **Step 4: Add `max_lifetime` passthrough to `create_harness/2`.**

In `lib/req_managed_agents/agent_core/client.ex`, `create_harness/2` builds `body`. After the base map, conditionally add the field (reuse the existing `maybe_put/3` helper in this module):

```elixir
def create_harness(c, spec) do
  body =
    %{
      "harnessName" => spec.name,
      "executionRoleArn" => spec.execution_role_arn,
      "systemPrompt" => system_prompt_blocks(spec.system_prompt),
      "model" => spec.model,
      "tools" => spec.tools
    }
    |> maybe_put("maxLifetime", Map.get(spec, :max_lifetime))

  span(c, :post, "/harnesses", :create_harness, fn -> post_json(c, "/harnesses", body) end)
end
```

- [ ] **Step 5: Run the tests to verify they pass.**

Run: `mix test test/req_managed_agents/agent_core/client_test.exs`
Expected: PASS (both new tests + existing `create_harness` test still green — it sets no `max_lifetime`, so `maybe_put` omits it).

- [ ] **Step 6: Commit.**

```bash
jj describe @ -m "feat(agent_core/client): configurable harness maxLifetime cost guardrail — MIM-50"
jj bookmark set ryan/mim50-spec -r @
jj new
```

---

### Task 6: [QA-CHECKPOINT — LIVE AWS] Validate against the eval gate

**Coverage:** the early-termination fix (Tasks 2–3) on the real cases that exhibited it (case_03/case_04), plus no regressions on the passing cases.
**Lifecycle preconditions:** app pinned to this branch's client SHA; `.env` + AWS creds; exec role `AgentCoreHarnessExecRole-p2b`.
**Expected duration:** ~15–20 min live.

**Files:** none (validation only) — record results in the app QA doc `biai-managed-agents/docs/qa/2026-06-28-arm3-harness-eval-qa.md`.

- [ ] **Step 1: Full client suite green offline.**

Run: `cd /Users/ryanmckeeman/src/bizinsights/req_managed_agents/.claude/worktrees/mim50-spec && mix test`
Expected: all pass, 4 excluded.

- [ ] **Step 2: Pin the app to this client branch + run the gate live.**

Bump the app `mix.exs` `req_managed_agents` ref to this branch's pushed SHA, `mix deps.update req_managed_agents`, then run the gate:

Run: `EVAL_EMBEDDER=voyage BUSINESS_ANALYST_RUNTIME=agentcore_harness BUSINESS_ANALYST_MODEL=bedrock:us.anthropic.claude-sonnet-4-5-20250929-v1:0 HARNESS_EXECUTION_ROLE_ARN=arn:aws:iam::819613816573:role/AgentCoreHarnessExecRole-p2b EVAL_MAX_ATTEMPTS=1 EVAL_CASE_TIMEOUT_MS=1200000 mix test test/managed_agents/business_analyst/parity/eval_parity_test.exs --only external`

Expected outcome by case:
- case_03 / case_04: **either** now complete with a real model result (validation pass/fail) **or** fail with the new explicit `{:error, {:harness_stream_error, ...}}` / `{:error, :early_termination}` (diagnosable) — NOT the old silent `{:terminal, :terminated, nil}`.
- case_01 / case_08: still PASS. case_02 / case_07: still their model/content results.

- [ ] **Step 3: Tear down + record.**

Delete any harness left running (`list-harnesses` → `delete-harness`). Append the run's vector + the case_03/04 outcome to the app QA doc.

- [ ] **Step 4: Commit the QA update (app worktree).**

```bash
# in biai-managed-agents/.claude/worktrees/mim39-p2b-app
jj describe @ -m "docs(qa): MIM-50 streaming-hardening validation — case_03/04 early-termination now surfaced/diagnosable"
jj bookmark set ryan/mim39-p2b-app -r @
jj new
```

---

### Task 7: SigV4 → `ex_aws_auth` (delete hand-rolled signer) — independent

**Context:** `ex_aws_auth` is *already* an optional dep, yet `sig_v4.ex` hand-rolls the canonical-request build + HMAC chain (63 LOC). Delegate to the library and delete the crypto. Independent of the spike; can run any time.

**Files:**
- Modify: `mix.exs` (promote `:ex_aws_auth` to a regular dep)
- Modify: `lib/req_managed_agents/agent_core/client.ex` (call sites) and/or `lib/req_managed_agents/agent_core/sig_v4.ex`
- Delete: `lib/req_managed_agents/agent_core/sig_v4.ex` (if fully replaced)
- Test: `test/req_managed_agents/agent_core/sig_v4_test.exs`, `test/req_managed_agents/agent_core/client_test.exs`

- [ ] **Step 1: Confirm `ex_aws_auth` covers our needs.** Read its docs/source for: SigV4 with a **session/security token** (`X-Amz-Security-Token`), the exact header set we sign (`host`, `x-amz-date`, content headers), and the `Authorization` header output. Record in the task whether it covers all cases. If it cannot sign with a session token, **stop and escalate** — keep the hand-rolled signer and note why (do not ship a signer that drops the session token).

- [ ] **Step 2: Promote the dep.** In `mix.exs`, change `{:ex_aws_auth, "~> 1.4", optional: true}` to `{:ex_aws_auth, "~> 1.4"}`. Run `mix deps.get`.

- [ ] **Step 3: Make the existing SigV4 tests the contract.** The current `sig_v4_test.exs` asserts a known signature for a fixed input. Keep those assertions — they are the behavioral contract the replacement must satisfy (SigV4 is deterministic, so a correct library produces the identical signature).
Run: `mix test test/req_managed_agents/agent_core/sig_v4_test.exs`
Expected: PASS (baseline, before the swap).

- [ ] **Step 4: Replace the signer body with an `ex_aws_auth` delegation, preserving the existing `SigV4.sign_request/…` interface** (so `client.ex` call sites are unchanged). Delete the hand-rolled canonical-request + HMAC helpers. (Exact call shape per Step 1's findings.)

- [ ] **Step 5: Run the full suite.**
Run: `mix test`
Expected: `sig_v4_test.exs` still PASS (identical signatures) + all `client_test.exs` signed-request assertions green.

- [ ] **Step 6: Commit.**

```bash
jj describe @ -m "refactor(agent_core): SigV4 via ex_aws_auth, delete hand-rolled signer — MIM-50"
jj bookmark set ryan/mim50-spec -r @
jj new
```

---

## Notes for the implementer

- **Task 1 gates Tasks 2–3.** If the spike shows the early termination is NOT an exception/error frame (e.g. a clean terminal variant our parser misreads, or a pure socket close), adjust: a parser-variant fix lands in `Converse.parse`/`terminal_atom` instead of Task 2's frame-tagging, and Task 3's `:early_termination` surface still applies.
- **Reference canonical from origin.** When re-aligning the decoder (Task 2), read `agentjido/req_llm` `lib/req_llm/providers/amazon_bedrock/aws_event_stream.ex` via `gh api` — NOT our local `cash-mckeeman/req_llm` fork (it is on `feat/ollama-provider` and may diverge).
- **Tasks 4, 5, and 7 are independent** of the spike and can proceed in parallel with 2–3 if desired; they are lower-priority hardening (the eval showed timeouts were not the dominant failure).
- **MIM-51** — after Task 2 lands and is live-validated, offer the `:message-type` exception surfacing as a PR to `agentjido/req_llm`.
- **`jj`, not git:** this repo uses jj colocated. Each task ends with `jj describe @` + `jj bookmark set` + `jj new` (forward-only). The plan's `git commit` header convention maps to those jj commands.
- After all tasks: push `ryan/mim50-spec`, open a PR, and the final client SHA gets pinned into the app.
