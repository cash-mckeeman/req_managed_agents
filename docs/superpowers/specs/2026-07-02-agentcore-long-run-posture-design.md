# AgentCore Long-Run Posture — Streaming Liveness Design (MIM-50)

**Date:** 2026-07-02
**Status:** Approved design (brainstorm complete; supersedes the issue title's "async + /ping" framing)
**Scope:** `ReqManagedAgents.AgentCore.Client.invoke_harness/2`, `ReqManagedAgents.Providers.BedrockAgentCore`, `ReqManagedAgents.Session` (one new `handle_info` clause + docs). No Provider behaviour changes.

---

## Problem

The AgentCore data plane is driven by one synchronous `InvokeHarness` HTTP call per turn.
Today `Client.invoke_harness/2` buffers the **entire** event-stream response body before
decoding, so `receive_timeout` (600 000 ms) is a wall-clock cap on the whole turn — even
when the harness is healthily streaming events the entire time. Long `analytical_deep_dive`
turns exceed it → `{:error, :timeout}`; a stream that dies mid-flight is indistinguishable
from a slow one until the full timeout elapses. Cranking the timeout up makes dead
connections cost proportionally more (session-hours and tokens billed for output we throw
away).

## Verified constraints (2026-07-02, AWS API reference + devguide)

1. **`InvokeHarness` is synchronous streaming only.** The API has no async/task mode, no
   invocation-status API, no event replay. Request: `POST /harnesses/invoke?harnessArn=…`
   with `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id`; response: one
   `vnd.amazon.eventstream` of Converse-shaped events ending in `messageStop`.
2. **`/ping` Healthy/HealthyBusy is the bring-your-own-container Runtime contract** — the
   agent container implements it. The Harness abstracts the container away; the pattern is
   unavailable at the Harness tier. (This retires the issue title's proposed mechanism.)
3. **Per-invocation server budgets exist:** `timeoutSeconds` (loop wall clock, harness
   default 3600), `maxIterations` (loop iterations, default 75), and `maxTokens`
   (per-iteration generation) are all overridable in the `InvokeHarness` body.
4. **The harness does not persist an uncommitted turn** (MIM-52 finding): a dropped stream
   loses that turn's work regardless of client posture. Reconnect-with-replay is not
   available; re-invoking re-runs the turn as a fresh generation.
5. `ReqManagedAgents.AgentCore.EventStream.decode/1` is **already incremental**:
   `binary -> {[event], remainder}` with partial trailing frames buffered in `remainder`.
6. `Session` runs `poll_turn/2` in a linked `Task` that messages `{:turn, result}` back to
   the Session GenServer — the Session mailbox is free during a turn, and messages from
   that one Task arrive FIFO.

## Decisions (from the brainstorm)

- **D1 — Streaming liveness, stay on Harness.** Replace whole-body buffering with
  incremental streaming; replace the wall-clock cap with an **inter-chunk idle timeout**.
  Dropping to the BYO-container Runtime tier for true async was rejected (abandons the
  managed-harness thesis; we would own the container, loop, and ping contract).
- **D2 — Live event delivery.** Fire `Handler.handle_event/2` and stream telemetry per
  event as it arrives, matching the Claude streaming provider's observational semantics.
- **D3 — Server-bounded guardrails.** Idle timeout default **300 000 ms**; **no**
  client-side wall clock on the turn. The authoritative run budget is server-side
  (`timeoutSeconds`/`maxIterations`/`maxTokens`), exposed as per-invocation opts.
- **D4 — Mechanism: Req `into:` reducer** (keep Req; keep `req_options` test injection;
  Bypass keeps working). Falsify the timeout assumption first (see Testing); fall back to
  `Finch.stream/5` on this one call path only if disproven.

---

## §1 Transport: streaming reducer in `Client.invoke_harness/2`

Signature and success/error contract unchanged: `{:ok, [event]} | {:error, reason}`.

Internals:

- The `Req.request` for the invoke gains `into: reducer` with accumulator
  `{event_acc, partial_buffer}`. Each `{:data, chunk}`: append chunk to buffer →
  `EventStream.decode/1` → append decoded events; when the invoke map carries an
  `:on_event` fun, call it per event, in order, as decoded.
- `receive_timeout` on this request is set from the invoke map's `:idle_timeout`
  (default `300_000`). With `into:` streaming, Finch applies the receive timeout per
  await, so it acts as the **inter-chunk liveness guard**, not a body cap. This is the
  design's one load-bearing transport assumption and is falsified by the first test
  (§5); the fallback is `Finch.stream/5` for this call only.
- On stream end, return `{:ok, events}` exactly as today (the buffered path's shape).
- Control-plane calls (`create/get/list/delete_harness`, credential providers) keep the
  existing buffered transport and `Client` `receive_timeout` semantics untouched.

## §2 Live delivery: subscriber messages + skip-batch rule

- `BedrockAgentCore.open/2` stops discarding its `subscriber` argument: the conn captures
  the Session pid. `invoke/3` sets
  `on_event = fn ev -> send(subscriber, {:provider_event, ev}) end` in the invoke map.
- Ordering: the `on_event` sends and the final `{:turn, result}` both originate in the
  same poll-turn Task → FIFO to the Session mailbox; all live events for a turn precede
  its `{:turn, …}`.
- `Session` gains one clause — `handle_info({:provider_event, ev}, s)`:
  1. `forward_raw(s, ev)` (existing handler-delivery helper),
  2. emit `[:req_managed_agents, :stream, :event]` telemetry with `s.meta` merged with
     the event's type (the same event name the Claude path emits — one observability
     surface for both providers),
  3. increment a per-turn `live_forwarded` counter in state.
- In `handle_info({:turn, {:ok, events, conn}}, s)`: batch `forward_raw` is **skipped iff
  `live_forwarded > 0`**, and the counter resets. Providers that never call `on_event`
  (test fakes, future backends) keep today's batch behavior with zero changes. No
  Provider behaviour/capability callback is added — opting in is calling the fun you
  were handed.

## §3 Budgets: server-bounded knobs

New opts accepted by `Session.run(BedrockAgentCore, …)` / `open/2` (all optional):

| Opt | Wire field | Default | Meaning |
|---|---|---|---|
| `:idle_timeout` | — (client-side) | `300_000` ms | max silence between chunks before the turn attempt is abandoned |
| `:timeout_seconds` | `timeoutSeconds` | nil (harness default 3600) | server-side loop wall clock, per invocation |
| `:max_iterations` | `maxIterations` | nil (harness default 75) | server-side loop iteration cap, per invocation |
| `:max_tokens` | `maxTokens` | nil | per-iteration generation cap |

- `open/2` threads them into the conn; `invoke/3` puts the three server fields into the
  request body via `maybe_put` (absent unless set — harness defaults rule).
- **No client wall-clock cap on the turn.** Liveness guards a dead transport; cost is
  bounded server-side.
- `Session.run/2`'s session-level `:timeout` (default 600 000 ms) is **unchanged**; its
  doc gains the interplay: for long runs set `:timeout` at or above your server budget —
  `idle_timeout` guards liveness, `timeoutSeconds`/`maxIterations` guard cost.
- The 300 s idle default must survive silent gaps while an in-microVM server-side tool
  (e.g. a long bash) runs. Whether the harness emits anything during such gaps is
  unverified — the live canary validates the floor (§5); the opt exists precisely so a
  deployment can raise it.

## §4 Errors and retry semantics

- An idle timeout surfaces as a Req transport error → the existing bounded retry in
  `invoke/3` (`:invoke_retries`, default 2) → then surfaced to the caller. Unchanged
  paths: `__stream_error__` frames are never retried; `stop_reason == nil` truncation
  retries then surfaces `:early_termination`.
- Because a retry restarts the turn as a **fresh generation** (constraint 4),
  `Handler.handle_event/2` becomes **at-least-once and may observe events from an
  aborted attempt**. This is documented on `Handler` and matches the Claude reconnect
  posture where `handle_event` is already the observational surface.
  `TurnResult.events` / `SessionResult.events` remain the canonical, exactly-once record
  (only the successful attempt's events).
- Partial decode buffers from a failed attempt are discarded with the attempt; no partial
  events leak into the returned `{:ok, events}`.

## §5 Testing

Bypass (real chunked HTTP through the full `Client` path):

1. **Liveness positive:** server streams frames at a steady cadence with total duration
   > `idle_timeout` → invoke succeeds. *Falsifies/confirms D4's per-chunk assumption;
   run first.*
2. **Liveness negative:** server sends one frame then stalls > `idle_timeout` → invoke
   fails with a transport timeout (and retries per `:invoke_retries`).
3. **Ordering:** `on_event` fires once per decoded event, in stream order, before
   `invoke_harness` returns.
4. **No double delivery (Session-level):** with live events flowing, the handler sees
   each event exactly once; with a fake provider that never calls `on_event`, batch
   delivery still works.
5. **Budget serialization:** `timeout_seconds`/`max_iterations`/`max_tokens` land in the
   request body under the wire names; absent by default.

Unit:

6. **Split-frame reduction:** an event-stream frame split across two chunks decodes via
   the `{events, remainder}` seam without loss or duplication.

Live (canary, `:live`-tagged):

7. Extend the AgentCore smoke to pass small `timeout_seconds`/`max_iterations` overrides
   and assert acceptance; observe idle-gap behavior during a server-side tool execution
   to validate the 300 s floor.

## Out of scope

- BYO-container Runtime tier, `/ping` management, true async task orchestration.
- Reconnect-with-replay for AgentCore (the harness offers no event replay; constraint 4).
- Claude provider changes (its SSE path already streams incrementally).
- Session-level cancellation of an in-flight turn (would motivate the Task+timer
  mechanism; deferred until a consumer needs it).
