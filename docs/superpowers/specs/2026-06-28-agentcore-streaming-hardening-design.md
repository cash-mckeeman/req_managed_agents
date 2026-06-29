# AgentCore Harness Streaming Hardening — Design (MIM-50)

**Status:** Draft for review · **Date:** 2026-06-28 · **Repo:** `req_managed_agents` (client lib)
**Related:** MIM-39 (P2b), MIM-48 (band-aids: PR #6 `list_harnesses`, PR #7 per-turn retry), MIM-44 (AWS setup)

## Goal

Make a single `InvokeHarness` turn survive long server-side work and transient
network drops — **without** leaving the managed Harness abstraction or adopting
asynchronous polling. The current AgentCore path holds a synchronous streaming
`InvokeHarness` connection open per turn; long analytical cases and mid-stream
drops fail those turns. This design hardens the *streaming* path, which is the
pattern both AWS and Anthropic endorse for long, interactive, tool-using calls.

## Context — why streaming, not polling

Three findings, all source-verified, shape this design:

1. **Anthropic recommends streaming, explicitly not polling, for long requests.**
   Their SDKs *refuse* a non-streaming request expected to exceed 10 minutes
   ("Streaming is required for operations that may take longer than 10 minutes").
   A steady SSE byte flow keeps the connection alive so networks don't idle-drop
   it. The async/polling option (Message Batches API) is bulk/offline — 24h
   turnaround, **no streaming, no tool use** — so it is disqualified for an
   interactive tool-using agent like business_analyst.
   ([streaming](https://docs.anthropic.com/en/api/messages-streaming),
   [batch processing](https://docs.anthropic.com/en/docs/build-with-claude/batch-processing))

2. **The AgentCore `Harness` data plane has no async/session-control operation.**
   The only data-plane op is `InvokeHarness` (`POST /harnesses/invoke`). The
   async + `/ping` HealthyBusy long-run surface lives entirely on the lower-level
   `Runtime` (`InvokeAgentRuntime`, `InvokeAgentRuntimeCommand`,
   `StopRuntimeSession`), which means bring-your-own-container. Adopting AWS async
   would mean dropping off Harness — deferred unless hardening proves insufficient.
   ([long-running agents](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-long-run.html))

3. **Billing punishes long/abandoned sessions.** Memory bills at
   $0.00945/GB-hr on *peak footprint, per-second, for the full session lifetime
   including idle* (CPU is active-cycles-only; plus Bedrock tokens). A dropped
   long call does not stop server-side work or refund it. Cranking timeouts higher
   without lifecycle discipline = longer, more expensive sessions.
   ([pricing](https://aws.amazon.com/bedrock/agentcore/pricing/))

**Architectural note:** our `invoke_to_completion` loop already chunks per turn —
each tool round-trip is a separate bounded `InvokeHarness` call on one
`runtimeSessionId`, *not* one multi-minute mega-stream. So the gap is not
architectural; it is that each per-turn stream is not yet robust.

## Non-goals

- **No Batches/polling** — no tool use, 24h latency; wrong tool.
- **No drop-to-Runtime / `/ping` async** — deferred; only revisited if the Phase 0
  spike proves Harness streaming is unsalvageable.
- **No app-loop changes** — the per-turn chunking in `invoke_to_completion` and the
  app adapter loop stay as they are. The app gains config knobs only.

## Wire-boundary cleanup (review addendum)

The hand-rolled wire code (`event_stream.ex` 132 LOC, `converse.ex` 129, `sig_v4.ex`
63 = 324 LOC) was flagged in review as "Jason gymnastics." Grounding against
**canonical `agentjido/req_llm`** (origin — *not* our `cash-mckeeman` fork on
`feat/ollama-provider`) settled the direction:

- **Elixir has no drop-in SDK for this.** Unlike boto3 / aws-sdk-go, the generic
  Elixir AWS SDKs (`:aws`, `ex_aws`) don't decode the Bedrock `vnd.amazon.eventstream`.
  The mature impl is req_llm's `AmazonBedrock.AWSEventStream` — what we ported from.
- **Our port drifted from canonical, for the worse.** Canonical does full CRC
  verification (prelude + message) and **returns `{:error, reason}`** on a bad/
  undecodable frame; **ours silently drops** undecodable frames (`{:error, _} -> acc`).
  The "gymnastics" is largely *our divergence*. Fix = re-align to canonical's
  error-propagating structure.
- **An exception-frame gap exists in canonical too.** Neither tags `:message-type`
  `exception`/`error` frames — both return a non-`:event-type` body as a raw map, so
  an early-termination exception becomes a shapeless map → `:terminated`/nil. Adding
  the surfacing is an improvement over upstream → **upstream PR candidate (MIM-51)**.

**Decision (this spec):** *make our decoder correct now, extract later.*
- **SigV4 → `ex_aws_auth`** (already an optional dep); delete the hand-rolled
  `sig_v4.ex`. Clean, separable, do regardless.
- **`event_stream.ex` → re-align to canonical** (CRC verification, `{:error, reason}`
  returns instead of silent drops) **+ add `:message-type` exception/error surfacing**
  (the case_03/04 fix). Offer the surfacing upstream (MIM-51).
- **Extraction** of a shared `aws_event_stream` lib is deferred to **MIM-43** (the
  `TODO(extract)` already in our code); not in MIM-50's scope.

## Architecture — four components

### Component 1: Spike / instrument (Phase 0 — gates the rest)

A throwaway probe (no production code) that captures **raw `InvokeHarness`
event-stream frame arrival timing** on the failing cases. It answers **two**
distinct questions — and the second is now the priority, because live eval data
(below) points away from idle-drop:

**Q1 — Idle-drop vs budget (the long-stream question).**
> Does the stream emit bytes steadily, or go silent for minutes during
> server-side reasoning / tool execution?

- **Silent gaps** → idle-drop is the enemy; keep-alive (Component 2) is load-bearing.
- **Steady frames** → the fixed 10-min ceiling was the only enemy; the timeout knob
  plus the shipped retry close it.

**Q2 — Diagnose the early-termination class (first-class outcome).**
The eval shows `case_03` failing **fast (~28 s), persistently, through the
per-turn retry**, with `{:terminal, :terminated, nil}`. That is **not** a
long-idle-drop and the retry does not fix it — so it is a different bug, and
naming it is a primary Phase 0 deliverable, not a footnote. The spike must
classify it as one of:

- **server-side early close** — the Harness terminates the session/stream early
  (guardrail, content policy, model error surfaced as a stream end);
- **bad tool input / loop state** — a specific `toolResult` or message shape that
  makes the harness end the turn without a `messageStop`;
- **client decode gap** — our `EventStream` decoder mis-handles a real terminal
  frame variant (e.g. an error event we don't classify), making a clean stop look
  like a truncation.

Concretely: capture the **full raw frame sequence** (headers + bodies, including
any error/exception frame) of a `case_03` invoke. The fix follows the
classification — and may be *content/decoder*, not *streaming*, at all.

**What the running eval already tells us:** with the 20-min cap + PR #7 retry,
`case_02` no longer times out — it **completes in ~287 s** and fails on *content*
(missing citation). So the "timeout budget" was secondary; the stream-drop +
early-termination behaviors are the real targets, and Q2 is where the unknown lives.

### Component 2: Keep-alive + configurable timeouts (Phase 1 — core)

Client-side (`ReqManagedAgents.AgentCore.Client` + `AgentCore` loop):

- **TCP keep-alive on the invoke socket.** Verify and explicitly set the
  Finch/Mint transport keep-alive options (`transport_opts: [keepalive: true]`).
  Caveat — keep-alive sends transport-level probes but **cannot manufacture
  application heartbeats**: if the Harness server itself goes byte-silent, an L7
  intermediary may still idle-drop the stream regardless. Whether keep-alive
  actually holds *our* path is precisely what the Phase 0 spike measures; if it
  cannot, the deferred Runtime/`/ping` path returns (see Risks).
- **Configurable `receive_timeout`** (per-turn socket ceiling) with a
  managed-appropriate default that is *not* a hardcoded 600 s. Today `Client.new/1`
  defaults `receive_timeout: 600_000`; this becomes a named, documented default
  with an override path.
- **Configurable loop deadline** (`invoke_to_completion :timeout`), already
  plumbed; the spec pins the relationship "loop deadline ≤ caller's case cap, with
  finalize headroom" so a clean `{:error, :timeout}` fires before any hard kill.

### Component 3: Drop resilience = bounded turn re-run (Phase 2 — formalize PR #7)

True mid-stream *resume* is not an LLM capability, so "resilience" means
**re-invoking the same messages on the same `runtimeSessionId`** when a turn's
stream is truncated or errors — exactly what PR #7 ships (`:invoke_retries`,
default 2). This phase absorbs that work and documents *why* re-run is the
ceiling: a turn carries no irreversible local side effect until its tools run, so
re-running is safe; resume-from-byte-offset is not available and is out of scope.

### Component 4: Cost guardrail (Phase 3)

- **Teardown discipline** — the app adapter already deletes the harness in its
  `after` block; the spec asserts this as a contract and adds a test.
- **Belt-and-suspenders max-lifetime** — a configured session/harness max-lifetime
  cap so an abandoned or hung session self-expires rather than billing idle memory
  for hours. Directly addresses finding #3.

## Failure taxonomy — three classes, three handlings

The spec names these so "timeout" and "drop" stop being conflated:

| Class | Signal | Handling |
|---|---|---|
| **Budget exceeded** | case legitimately needs more wall-clock | NOT retried; clean `{:error, :timeout}`; raise the *budget* via config, never via retries |
| **Transient drop** | `stop_reason: nil` / transport error that **succeeds on re-run** | bounded turn re-run (Component 3); the retry resolves it |
| **Persistent early termination** | `stop_reason: nil` that **recurs through the retry** (e.g. `case_03`: fast, ~28 s, every attempt) | re-run does NOT fix it — surface a distinct, diagnosable error; root cause is content / guardrail / decoder (Component 1 Q2), not transport |
| **Real terminal** | `end_turn`, `stop_sequence`, or unknown like `content_blocked` | mapped to terminal; never retried |

The third row is the key correction the eval forced: a truncation that survives
retry is **not** a transport blip and must not be silently swallowed as one — it
needs its own error surface so it is diagnosed, not papered over.

## Data flow (hot path, hardened)

```
loop turn → invoke_turn(messages, session_id)
  → Req POST /harnesses/invoke   [keep-alive ON, receive_timeout = managed default]
     ├─ steady frames        → EventStream.decode → messageStop → parse → {:ok, complete}
     ├─ silent > interval     → TCP keep-alive holds socket → no idle drop
     ├─ truncated (nil stop)  → bounded turn re-run        (Component 3)
     └─ transport error       → bounded turn re-run        (Component 3)
  → retries exhausted          → surface {:error, reason} to app finalize
```

## Testing

All unit tests are offline via the `invoke_fun` seam + `Bypass` — no live AWS in
the suite. Live validation stays in the app's `:external` eval gate.

- **Keep-alive / stall:** a `Bypass` server that sends a frame, pauses past the old
  idle window, then resumes and completes → asserts the turn completes rather than
  dropping.
- **Failure-class matrix:** budget-exceeded → `:timeout` (not retried); truncated →
  retried then completes; persistent transport → surfaces error after bound; real
  terminal (`content_blocked`) → not retried. (Extends the PR #7 tests.)
- **Guardrail:** a session past max-lifetime is stopped / torn down; adapter
  `after`-block teardown is asserted.

## QA surface

Per the qa-checkpoint convention: the user-facing validation milestone is the
**business_analyst `:external` eval gate** run through `:agentcore_harness` on a
long `analytical_deep_dive` case — the same gate that surfaced the problem. A
`[QA-CHECKPOINT]` belongs at the end of Phase 1 (keep-alive + timeout) and again
after Phase 3, asserting the previously-timing-out cases complete and no harness
is left running.

## Risks / open questions

- **Phase 0 may show steady frames** — then Component 2's keep-alive is belt-only
  and Phase 1 collapses to "make the timeout default sane." That is a *good*
  outcome (less work); the spike exists to find out before building.
- **Harness may go genuinely silent for >TCP-keepalive windows** through an AWS
  intermediary we don't control — if keep-alive cannot hold it, the deferred
  Runtime/`/ping` path (MIM-50 follow-up) returns to the table. The spike is the
  decision point.
- **`case_03` may not be a streaming bug at all.** If Phase 0 Q2 classifies it as
  a **content / guardrail** early-close or a **decoder** gap, the fix is *not*
  streaming hardening — it leaves this spec's scope and becomes its own work item
  (a decoder fix here, or an agent/content issue in the app). This spec's
  contribution to it is the **diagnosis + a distinct error surface** (taxonomy row
  3), not a guaranteed fix. Do not let it block Phases 1–3.

- **Re-run idempotency** for tools with side effects — business_analyst tools are
  read-mostly (retrieve / query / emit), so re-run is safe here; a future agent
  with mutating tools would need idempotency keys. Noted, not solved here.

## References

- Anthropic streaming / long requests — https://docs.anthropic.com/en/api/messages-streaming
- Anthropic Message Batches — https://docs.anthropic.com/en/docs/build-with-claude/batch-processing
- AgentCore long-running agents — https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-long-run.html
- AgentCore pricing — https://aws.amazon.com/bedrock/agentcore/pricing/
- MIM-50 (this design), MIM-48 (band-aids), MIM-39 (P2b)
