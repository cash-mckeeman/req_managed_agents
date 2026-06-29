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

## Architecture — four components

### Component 1: Spike / instrument (Phase 0 — gates the rest)

A throwaway probe (no production code) that captures **raw `InvokeHarness`
event-stream frame arrival timing** on one long `analytical_deep_dive` case. The
single question it answers:

> Does the stream emit bytes steadily, or go silent for minutes during
> server-side reasoning / tool execution?

- **Silent gaps** → idle-drop is the real enemy; keep-alive (Component 2) is the
  load-bearing fix.
- **Steady frames** → the fixed 10-min ceiling was the only enemy; the timeout
  knob (Component 2) plus the already-shipped retry largely close it.

The currently-running 20-min-cap eval supplies half this data point already: if
the previously-timed-out `case_02` / `case_07` now pass, budget was the whole story.

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
| **Truncated / transport drop** | `stop_reason: nil` (no `messageStop`) or `{:error, transport}` | bounded turn re-run (Component 3) |
| **Real terminal** | `end_turn`, `stop_sequence`, or unknown like `content_blocked` | mapped to terminal; never retried |

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
- **Re-run idempotency** for tools with side effects — business_analyst tools are
  read-mostly (retrieve / query / emit), so re-run is safe here; a future agent
  with mutating tools would need idempotency keys. Noted, not solved here.

## References

- Anthropic streaming / long requests — https://docs.anthropic.com/en/api/messages-streaming
- Anthropic Message Batches — https://docs.anthropic.com/en/docs/build-with-claude/batch-processing
- AgentCore long-running agents — https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-long-run.html
- AgentCore pricing — https://aws.amazon.com/bedrock/agentcore/pricing/
- MIM-50 (this design), MIM-48 (band-aids), MIM-39 (P2b)
