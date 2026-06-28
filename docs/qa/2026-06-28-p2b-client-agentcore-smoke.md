# AgentCore Harness End-to-End Smoke — P2b Client

**Date:** 2026-06-28
**Linear:** MIM-39 P2b

## What it covers

The unit tests for `AgentCore.Client`, `EventStream`, `Converse`, and `SigV4`
each stub the layer below them. The smoke drives the entire composed stack in a
single pass:

    SigV4.sign_request → Req.new/merge → stub adapter (replaces HTTP) →
    EventStream.decode → Converse.parse → tool handler → Converse.resume_messages →
    second invoke (SigV4 again) → EventStream → Converse.parse → end_turn →
    AgentCore.invoke_to_completion return

The stub adapter is injected via `req_options: [adapter: fn]` — only the TCP
transport is replaced. Everything else runs for real, in-process, in any Mix
env (no Bypass, no Plug).

Eight stages are verified in one run (three standalone + five from the tool
loop):

| Stage | What it checks |
|---|---|
| SigV4 header well-formed | `sign_request/4` produces valid `authorization` + `x-amz-date` headers |
| EventStream multi-frame + remainder | Two complete frames decode; a truncated third becomes the remainder |
| Converse.inline_function shape | NimbleOptions schema → `inlineFunction.inputSchema.json` structure |
| SigV4 signed | Every `invoke_harness` HTTP call carried `AWS4-HMAC-SHA256` |
| tool_use decoded+parsed | The tool loop ran and the resume turn fired |
| strict resume contract | Resume body contained both `assistant` (toolUse) and `user` (toolResult) roles |
| tool text round-trip | `toolResult` text in the resume body equals `"echoed: hi"` |
| terminal end_turn | `invoke_to_completion` returned `{:ok, %{terminal: :end_turn}}` |

## How to run

```bash
mix req_managed_agents.agent_core.smoke
```

No AWS credentials needed — the stub adapter intercepts before any network call.

The smoke also runs under `mix test` via
`test/req_managed_agents/agent_core/smoke_test.exs`.

## Expected output

```
[PASS] SigV4 header well-formed — authorization (AWS4-HMAC-SHA256) + x-amz-date present
[PASS] EventStream multi-frame + remainder — 2 messages decoded; 5-byte remainder retained
[PASS] Converse.inline_function shape — inlineFunction.inputSchema.json has topic property with type "string"
[PASS] SigV4 signed — 2 invoke request(s) carried AWS4-HMAC-SHA256 Authorization
[PASS] tool_use decoded+parsed — tool loop ran; resume turn was reached
[PASS] strict resume contract — resume body roles: ["assistant", "user"]
[PASS] tool text round-trip — toolResult text == "echoed: hi"
[PASS] terminal end_turn — invoke_to_completion returned {:ok, %{terminal: :end_turn, stop_reason: "end_turn"}}

All 8 stages passed.
```

## What this does NOT cover (live-gate, Task 9)

- Real AWS SigV4 clock-skew / credential expiry
- Actual AgentCore service reachability and session lifecycle
- Network-level TLS / latency / streaming chunking
- Harness provisioning (create/get/delete) over the real control plane

Those gaps are covered by the Task 9 live checkpoint using a minted vault key
against the real `bedrock-agentcore` endpoint.
