# Provider Streaming Abstraction — Design Spec

**Date:** 2026-06-29
**Status:** Draft (design approved; implementation-ready)
**Related:** MIM-43 (provider extraction endgame), MIM-52 (Converse tool-id keying), `2026-06-28-aws-event-stream-design.md`

## Motivating question

> *"Do we need an `ant_event_stream` library for Elixir like we have for AWS?"*

**No.** The thing that justified `aws_event_stream` was a **custom binary framing protocol** (`vnd.amazon.eventstream`: prelude + headers + payload + CRC32) for which no Elixir decoder existed. That situation does not recur for Anthropic.

- **AWS Bedrock** streams are binary-framed → require a bespoke codec.
- **Anthropic** (both the native Messages API and the Managed Agents control plane) streams over **Server-Sent Events** — a standardized *text* protocol (`text/event-stream`, `data:`/`event:` lines, `\n\n`-delimited). RMA already decodes it in `ReqManagedAgents.SSE` (`@spec decode(binary()) :: {[map()], binary()}`), and mature Hex libraries (`server_sent_events`, `req_sse`) exist if we ever want to externalize it.

Building a binary `ant_event_stream` would be inventing a problem to match a solution. The real obstacle to provider-agnosticism is **not the transport codec** — it is that semantic normalization (raw provider events → a common turn model) exists for exactly one of RMA's two backends today. This spec defines that seam.

## Goal

Establish a single canonical turn vocabulary and a `ReqManagedAgents.Provider` behaviour, then refactor RMA's two existing streaming backends to implement it — so that adding a third backend means writing one behaviour implementation, not threading a new event shape through the drivers.

## Core distinction: provider-executed vs client-executed tools

This is the **thesis of the repository** and the load-bearing concept of the abstraction: the **provider runs the agent loop; the client executes only the tools the provider returns control for.** Every tool a model invokes is one of two kinds, and they are handled at opposite ends:

- **Server-side / built-in tools** (web search, code interpreter, file ops, …): the provider's managed loop executes these *itself* and continues. The client observes their **`tool_use` and `tool_result` events** in the stream (history, telemetry) but **never** runs them and **never** submits a result for them. They do **not** pause the loop.
- **Custom tools** (client-side / return-of-control — the app's domain tools, exposed via `agent.custom_tool_use` / Bedrock `inline_function`): the provider's loop *pauses*, surfaces the call to the client, the client runs it locally via the `Handler`, and the client submits a **`custom_tool_result`** to resume the loop.

We adopt **Anthropic's own `custom_tool_use` / `custom_tool_result` vocabulary as canonical** (Bedrock's `inline_function` / `toolResult` map onto it). This is deliberate and not cosmetic: a single stream legitimately contains **both** a provider-emitted server-side `tool_result` *and* a `custom_tool_result`. A bare `tool_result` canonical name would let consumers read the two species as the same thing; the `custom_` qualifier is what keeps them distinct. Same reasoning on the use side: `custom_tool_use` (actionable) vs a server-side `tool_use` (observe-only).

The existing code already encodes this distinction in its wire vocabulary — the spec must honor it, not flatten it:

| | Custom (return-of-control) | Server-side (provider-executed) |
|---|---|---|
| **Managed Agents** | `agent.custom_tool_use` + `session.status_idle`/`requires_action` with `event_ids`; result `user.custom_tool_result` | server-side `tool_use`/`tool_result` events (stream through; not in `event_ids`) |
| **Bedrock AgentCore** | `inline_function` toolUse → `stopReason: "tool_use"`; result `toolResult` | harness built-in tools (executed in-microVM; no `tool_use` stop) |

**Consequence for the contract:** `normalize/1` MUST surface **only custom (client-side) tool uses** as actionable `custom_tool_uses`. Server-side tool activity must never enter that list — if it did, the driver would hand the `Handler` a tool the provider already ran. `:requires_action` means precisely "one or more *custom* tools are pending." Server-side `tool_use`/`tool_result` events remain in the raw `events` (preserved, observable, and never renamed to `custom_*`) and are out of the actionable path.

## Scope

**In scope (this spec):** unify the **two existing backends** behind one behaviour:

1. **Managed Agents** — `ReqManagedAgents.Client` over `https://api.anthropic.com` (`anthropic-beta: managed-agents-2026-04-01`), streamed via `ReqManagedAgents.SSE`, driven by `ReqManagedAgents.RunToCompletion`.
2. **Bedrock AgentCore** — `ReqManagedAgents.AgentCore.Client` over `bedrock-agentcore.<region>.amazonaws.com`, streamed via `ReqManagedAgents.AgentCore.EventStream`, normalized by `ReqManagedAgents.AgentCore.Converse`, driven by `ReqManagedAgents.AgentCore.invoke_to_completion/1`.

**Implementation outcome:** the Managed Agents side turned out to have a *third* turn driver beyond `RunToCompletion` — the stateful `ReqManagedAgents.Session` GenServer — which was also migrated onto `Providers.ClaudeManagedAgents` (it has no full event list, so it calls `normalize/1` on a synthetic per-turn list, `Map.values(stash) ++ [status_event]`). So **all three drivers** (`RunToCompletion`, `Session`, `AgentCore.invoke_to_completion/1`) now emit the canonical 3-atom terminal — the collapse is uniform. `Event.classify/1` is **retained**, not retired: it still backs `ReqManagedAgents.Profile`'s wire-compat `terminal?/3` predicate (currently unused scaffolding). Migrating `Profile` off `classify` and then retiring `classify` is explicit follow-up.

**Review-confirmed behaviors & known limitations** (from the whole-branch review):

- **Empty `custom_tool_uses` on `:requires_action`.** If a `requires_action` idle's `event_ids` reference ids not present as `agent.custom_tool_use` events, `normalize/1` returns `:requires_action` with `custom_tool_uses: []`. Both drivers `resolve([])` → no-op continue, identical to pre-refactor behavior. The "non-empty iff" phrasing is therefore relaxed to "populated only on `:requires_action`."
- **Untyped / null-`stop_reason` `status_idle`.** `ManagedAgents.normalize/1` treats an idle with no recognizable `stop_reason.type` (e.g. jido's creation-time/null idle) defensively as `:terminated` rather than crashing or hanging. The anthropic shape this provider targets always carries a typed `stop_reason`; jido's *context-dependent* verdict ("agent seen?") lives in `ReqManagedAgents.Profile` and is the follow-up that would wire jido into these drivers.
- **Accepted observability deltas of the collapse.** `SemConv.finish_reason/1` retains `:error`/`:retries_exhausted` clauses that are now unreachable from the three drivers (still valid for direct callers/tests; harmless). `Session`'s `:notify` tuple `{:managed_agents_session, terminal}` carries only the collapsed atom (no `stop_reason`), so a notify consumer can no longer distinguish `:error`/`:retries_exhausted`; changing the tuple shape would break the public contract, so it is left as-is.

**Out of scope (explicitly):**

- **Building `ant_event_stream`** — rejected above.
- **A native Anthropic Messages API provider** (`/v1/messages`) — the behaviour is *designed to admit* one later, but this spec does not build it.
- **Generic OpenAI/Google providers** — premature before a third real backend exists.
- **Merging the two drivers into one loop.** Both backends are stateful, session-scoped (see "Session model" below), but they differ in *invocation model* — Managed Agents is a long-lived push stream; AgentCore is per-turn request/response — which are legitimately different control-flow topologies. They will share *vocabulary and building blocks*, not a single loop. A unified driver is a possible future once a third backend reveals whether one is warranted.

## Architecture

Three layers, two of which already exist and converge:

```
        ┌─────────────────────── Transport (exists, already convergent) ───────────────────────┐
        │  SSE.decode/1 :: {[map()], binary()}        EventStream.decode/1 :: {[map()], binary()}│
        └───────────────────────────────────────────────────────────────────────────────────────┘
                                          │ raw provider events (string-keyed JSON maps)
                                          ▼
        ┌─────────────────────── Normalization (the new seam) ──────────────────────────────────┐
        │  Provider.normalize/1 :: [event] -> turn_outcome                                       │
        │  Provider.terminal/1  :: stop_reason -> terminal                                       │
        │  Provider.resume/2    :: ([custom_tool_use], [custom_tool_result]) -> continuation     │
        └───────────────────────────────────────────────────────────────────────────────────────┘
                                          │ turn_outcome (custom_tool_uses only) + custom_tool_result
                                          ▼
        ┌─────────────────────── Drivers (stay distinct; consume canonical vocabulary) ─────────┐
        │  RunToCompletion.run/1 (stateful push)      AgentCore.invoke_to_completion/1 (per-turn)│
        │  both return {:ok, %{terminal, stop_reason, events}}  (already a shared shape)         │
        └───────────────────────────────────────────────────────────────────────────────────────┘
```

The transport contract (`{[map()], binary()}`) and the driver result shape (`{:ok, %{terminal, stop_reason, events}}`) are **already identical** across both backends today — half the abstraction is accidentally done. The new work is the middle layer plus a terminal-taxonomy unification.

### Session model: both backends are stateful

Both backends maintain server-side session state, so neither driver resends full conversation history:

- **Managed Agents** — `session_id`-scoped. The server holds the event log; the driver POSTs new events (`user.message`, `user.custom_tool_result`) and reads pushed events.
- **Bedrock AgentCore** — `runtimeSessionId`-scoped (a kept-alive microVM with short-term memory, per AWS docs). The driver sends only the *delta* that completes a turn — on a tool-use pause, the assistant `toolUse` (uncommitted until results arrive) plus the `toolResult` — never the accumulated history. Confirmed empirically: multi-turn tool loops succeed though the original prompt is never resent.

What differs between them is therefore **not** statefulness but: wire framing (binary `vnd.amazon.eventstream` + SigV4 vs SSE + `x-api-key`), invocation model (per-turn request/response vs long-lived push stream), and resume shape (delta messages vs POSTed result events). These are platform / API-contract differences. The *semantic* layer — turn structure, tool-use blocks, stop reasons — converges because Bedrock Converse is modeled on Anthropic's Messages API. That semantic convergence (shared API lineage, **not** shared compute substrate) is what makes a single canonical vocabulary feasible.

## The canonical vocabulary

Internal representation (atom-keyed — these are RMA-internal types, distinct from the string-keyed wire maps). Defined in `ReqManagedAgents.Provider`:

```elixir
@type event :: %{required(String.t()) => term()}   # a raw, decoded provider event (wire shape)

# A CUSTOM (client-side, return-of-control) tool call the client must execute locally.
# Anthropic's own term; the Managed wire is `agent.custom_tool_use`, Bedrock's is the
# `inline_function` toolUse. Server-side / built-in tool uses are NOT represented here.
@type custom_tool_use :: %{id: String.t(), name: String.t(), input: map()}

# A locally-produced result for a custom_tool_use — what we SUBMIT to resume the loop.
# Deliberately named `custom_` (not bare `tool_result`): the event stream also carries
# provider-emitted SERVER-SIDE `tool_result`s, and the qualifier keeps the two species
# from ever being read as the same thing. Anthropic wire: `user.custom_tool_result`.
@type custom_tool_result :: %{tool_use_id: String.t(), text: String.t(), is_error: boolean()}

@type terminal :: :end_turn | :requires_action | :terminated

@type turn_outcome :: %{
        terminal: terminal(),
        stop_reason: String.t() | nil,           # raw provider string, preserved for fidelity
        custom_tool_uses: [custom_tool_use()],   # return-of-control tools to run locally;
                                                 # populated only on terminal == :requires_action
                                                 # (else []; may also be [] if the server's
                                                 # event_ids reference no stashed custom tool).
                                                 # Server-side tool activity is excluded by design.
        text: String.t()                         # assistant text; best-effort (see "text field" below)
      }
```

`custom_tool_result` is **already shared** by both backends today: `Event.custom_tool_result/3` and `Converse.resume_messages/2` both consume `%{tool_use_id, text, is_error}`, and `Tools.run/6` produces it. We promote the existing de-facto type to the behaviour; no change to `Tools`. Server-side / built-in tool use and tool **results** are intentionally absent from this canonical vocabulary — they are the provider's responsibility, surface only as raw `events`, and are never named `custom_*` (see "Core distinction" above).

### Terminal taxonomy

One canonical set; each provider maps its raw stop reasons into it. The raw string is always preserved in `turn_outcome.stop_reason`, so fidelity (e.g. `retries_exhausted` vs `guardrail_intervened`) is never lost — `terminal` is for control flow, `stop_reason` for diagnosis.

| Canonical `terminal` | Managed Agents raw → | Bedrock raw → |
|----------------------|----------------------|---------------|
| `:end_turn`          | `status_idle` / `end_turn` | `messageStop` / `end_turn`, `stop_sequence` |
| `:requires_action`   | `status_idle` / `requires_action` (with `event_ids`) | `messageStop` / `tool_use` |
| `:terminated`        | `status_terminated`, `session.error`, `status_idle` / `retries_exhausted`, `unknown_idle` | `messageStop` / `max_tokens`, `guardrail_intervened`, any unrecognized |

`:requires_action` always means **client-side** tools are pending (see "Core distinction"). A provider that runs a *server-side* tool does not stop the loop, so it never produces `:requires_action` for that tool — it streams the activity and continues to a real terminal.

Driver-level conditions that are **not** provider terminals — `:early_termination`, `:timeout`, `:harness_stream_error` (a surfaced AWS exception frame), `:create_session_failed` — remain in their respective drivers and are **not** part of the `Provider` behaviour. The behaviour models what the *model/turn* did, not what the *transport* did.

### The `text` field

`stop_reason`, `terminal`, and `custom_tool_uses` are the control-flow-critical fields and are **fully specified for both backends from confirmed event shapes** (below). `text` is part of the canonical type but populated **best-effort** per provider:

- **Bedrock:** already assembled by `Converse.parse/1` from `contentBlockDelta` `text` deltas. Confirmed.
- **Managed Agents:** `RunToCompletion` does not currently assemble assistant text, and no driver's control flow depends on it. The managed `normalize/1` MUST populate `text` from the assistant-text event present in the stream; the exact event shape is to be read from a captured golden stream during implementation (see Testing) rather than guessed here. Until captured, managed `text` defaults to `""`. This is a forward-compatible field, not a blocker.

## The `Provider` behaviour

```elixir
defmodule ReqManagedAgents.Provider do
  @moduledoc """
  Contract a streaming agent backend implements so RMA's drivers can speak one
  canonical turn vocabulary regardless of wire protocol (binary EventStream vs SSE)
  or invocation model (per-turn request/response vs long-lived push stream). Both
  backends are stateful, session-scoped.
  """

  # ... canonical @type definitions above ...

  @doc "Reduce a streaming byte buffer to decoded events + leftover. (Transport seam.)"
  @callback decode(binary()) :: {[event()], binary()}

  @doc """
  Fold one turn's accumulated events into the canonical turn outcome. MUST surface
  only client-side (return-of-control) tool calls in `custom_tool_uses`; server-side
  tool activity stays in the raw events and out of the actionable path.
  """
  @callback normalize([event()]) :: turn_outcome()

  @doc "Map a provider-raw stop reason to the canonical terminal atom."
  @callback terminal(stop_reason :: String.t() | nil) :: terminal()

  @doc """
  Build the provider-specific continuation that submits locally-executed tool results.
  Bedrock returns the strict two-message resume list; Managed Agents returns the
  list of `user.custom_tool_result` events to POST. Opaque to the driver.
  """
  @callback resume(custom_tool_uses :: [custom_tool_use()], results :: [custom_tool_result()]) :: term()
end
```

`decode/1` is included in the behaviour for completeness and discoverability, but each provider's `decode` is a one-line delegation to the existing `SSE` / `EventStream` module — those stay as-is.

## Component responsibilities

### `ReqManagedAgents.Provider` (new)
Behaviour + canonical types only. No logic.

### `ReqManagedAgents.Providers.BedrockAgentCore` (new, thin)
`@behaviour ReqManagedAgents.Provider`. Composes existing AgentCore pieces:
- `decode/1` → delegates `AgentCore.EventStream.decode/1`.
- `normalize/1` → wraps `AgentCore.Converse.parse/1`, mapping its `%{"toolUseId", "name", "input"}` entries to canonical `custom_tool_use` `%{id, name, input}` and its raw `stop_reason` to a canonical `terminal` via `terminal/1`. The toolUse blocks `parse/1` surfaces (at `stopReason: "tool_use"`) are the return-of-control `inline_function` calls — client-side by construction; harness-executed built-in tools do not produce a `tool_use` stop and so never appear here.
- `terminal/1` → the mapping currently inlined as `AgentCore.terminal_atom/1`, extended so `"tool_use"` ⇒ `:requires_action`.
- `resume/2` → wraps `AgentCore.Converse.resume_messages/2` (canonical `custom_tool_use` → the assistant `toolUse` wire blocks it already builds).

`Converse.parse/1`, `resume_messages/2`, and `inline_function/3` keep their current internals (including the MIM-52 id-keyed fold) — they are wrapped, not rewritten.

### `ReqManagedAgents.Providers.ClaudeManagedAgents` (new)
`@behaviour ReqManagedAgents.Provider`. The genuinely new normalization, built on confirmed event shapes:
- `decode/1` → delegates `ReqManagedAgents.SSE.decode/1`.
- `normalize/1` → folds the event list. Accumulates `agent.custom_tool_use` events (`%{"id", "name", "input"}`) — the `custom_` prefix marks these client-side. On a `session.status_idle`, reads `stop_reason.type`; when `"requires_action"`, emits `custom_tool_uses` = the accumulated custom-tool-use events whose `id ∈ stop_reason.event_ids`, as canonical `%{id, name, input}`, in `event_ids` order; sets `terminal` via `terminal/1` and `stop_reason` to the raw type string. (Mirrors how `Converse.parse/1` emits client tool uses on `stopReason: "tool_use"`.) Any provider-executed tool events seen along the way stay in the raw `events` and are never added to `custom_tool_uses`. Populates `text` best-effort.
- `terminal/1` → the mapping currently inlined as `Event.classify/1`'s `status_idle` branch, collapsed to the canonical three (preserving the raw string in `stop_reason`).
- `resume/2` → maps canonical `custom_tool_result`s to `Event.custom_tool_result/3` events (the wire shape `RunToCompletion.resolve/2` posts today).

### Drivers (refactored, topology unchanged)
- **`AgentCore.invoke_to_completion/1`** — replace direct calls to `Converse` / `EventStream` / `terminal_atom` with `Providers.BedrockAgentCore.{decode,normalize,terminal,resume}`. The MIM-52 telemetry sentinel (`emit_tool_use_telemetry/2`) moves to operate on canonical `custom_tool_uses`. Per-turn loop unchanged.
- **`RunToCompletion.run/1`** — `do_event/3` and `resolve/2` consume `Providers.ClaudeManagedAgents.normalize/1` to obtain canonical `custom_tool_uses` + `terminal` at a `requires_action` idle, and `Providers.ClaudeManagedAgents.resume/2` to build the result events. Stateful push-loop, `seen` de-dup, and the `Stream`/`Task` plumbing are unchanged.

Both drivers keep returning `{:ok, %{terminal: terminal(), stop_reason: term(), events: [event()]}}` — now with `terminal` drawn from the unified taxonomy.

## Confirmed wire shapes (basis for the normalizers)

**Managed Agents** (from `ReqManagedAgents.Event`, `RunToCompletion`):
- Client-side tool call: `%{"type" => "agent.custom_tool_use", "id" => id, "name" => name, "input" => map}`
- Requires action: `%{"type" => "session.status_idle", "stop_reason" => %{"type" => "requires_action", "event_ids" => [id, …]}}` — `event_ids` references only client-side `custom_tool_use`s
- Server-side tool activity: provider-executed tool events that are **not** referenced by a `requires_action` `event_ids`; the exact event types are to be confirmed from a golden fixture and must be excluded from `custom_tool_uses`
- Other terminals: `status_idle`/`end_turn`, `status_idle`/`retries_exhausted`, `session.status_terminated`, `session.error`
- Tool result (outbound): `Event.custom_tool_result(custom_tool_use_id, text, is_error: bool)`

**Bedrock AgentCore** (from `AgentCore.Converse`, `AgentCore.EventStream`):
- Client-side tool call: `contentBlockStart` → `start.toolUse.{toolUseId,name}` (a return-of-control `inline_function`), input streamed via `contentBlockDelta.delta.toolUse.input` fragments, signalled by `stopReason: "tool_use"`
- Server-side tool activity: harness built-in tools execute in-microVM and do **not** surface a `tool_use` stop; if any related events appear in the stream they must be excluded from `custom_tool_uses` (confirm via golden fixture)
- Terminal: `messageStop.stopReason` ∈ `end_turn | stop_sequence | tool_use | max_tokens | guardrail_intervened | …`
- Resume: `resume_messages/2` → `[assistant toolUse msg, user toolResult msg]`

## Testing

TDD per the implementation plan. Key strategy:

1. **Golden event fixtures per backend.** Reuse/extend the existing `event_stream_test.exs` (Bedrock) and `sse_test.exs` (Managed) corpora; capture a real Managed Agents `requires_action` turn (including the assistant-text event) as a golden fixture to pin the `text` shape rather than guess it.
2. **Behaviour conformance test** (shared): for each provider module, assert it implements all `Provider` callbacks and that `normalize/1` of its golden fixture yields a well-formed `turn_outcome` — `terminal` in the canonical set, `custom_tool_uses` matching canonical `%{id, name, input}`, `custom_tool_uses` populated only on `:requires_action` (empty for terminal outcomes; see "Review-confirmed behaviors").
3. **Server-side exclusion test** (the thesis guard): a fixture containing both a client-side (return-of-control) tool call *and* a server-side/built-in tool use+result normalizes to `custom_tool_uses` holding **only** the client-side call; the server-side activity remains in `events` and never reaches the actionable path. One per backend.
4. **Cross-provider symmetry test:** a `requires_action`/`tool_use` fixture from each backend normalizes to the *same canonical shape* (modulo ids/names), proving the vocabulary is genuinely shared.
5. **MIM-52 regression preserved:** the index-reuse vector (`[{0,A},{0,B},{1,C}]`) still recovers both tools through `Providers.BedrockAgentCore.normalize/1`.
6. **Driver tests unchanged in behavior:** existing `RunToCompletion` and `invoke_to_completion` tests pass without modification to their assertions (the refactor is internal).

## Migration / risk

- **Low-risk, additive.** New `Provider` + two thin provider modules wrap working internals; `Converse.parse/1`, `EventStream.decode/1`, `SSE.decode/1`, `Tools.run/6`, and both drivers' loop topologies are preserved.
- **One behavioral unification:** the terminal taxonomy collapses to three atoms. Any caller pattern-matching on the old richer managed atoms (`:retries_exhausted`, `:unknown_idle`) must switch to inspecting `stop_reason`. This is the only externally observable change and must be called out in the plan with a grep of call sites.
- **No new dependencies.** SSE and EventStream decoding stay in-tree. (A future extraction may adopt `aws_event_stream` for the binary side and `server_sent_events` for the SSE side — symmetric, and we author only the binary one because the SSE one already exists.)

## Non-goals recap

- No `ant_event_stream` binary codec — there is no binary protocol to decode.
- No native Messages API provider, no OpenAI/Google providers, no merged driver — the behaviour is designed to admit these; this spec does not build them.

## Resolved decisions

- **Module namespace: `ReqManagedAgents.Providers.{AgentCore,ManagedAgents}`.** Thin behaviour-implementing modules that compose the existing internals; keeps providers discoverable and parallel.
- **Terminal taxonomy collapses to three atoms** (`:end_turn` / `:requires_action` / `:terminated`). The raw provider string is preserved in `turn_outcome.stop_reason`, so `:retries_exhausted`/`:unknown_idle`/`:guardrail_intervened` fidelity is available there. This is the one externally observable change (see Migration / risk).
- **Server-side tool activity stays in raw `events` for v1.** No `server_tool_uses` / `server_tool_results` fields on `turn_outcome`. The species is named and excluded from `custom_tool_uses`; surfacing it as a dedicated observability field is a clean additive follow-up if a consumer needs it.

## Open decisions for plan-time

- Whether `decode/1` belongs in the behaviour at all, or whether transport stays out-of-band (the drivers already call `SSE`/`EventStream` directly). Included for now for one-stop discoverability; trivially removable.
- Minor: align the `custom_tool_result` field `tool_use_id` to Anthropic's `custom_tool_use_id` (ripples into `Tools.run`/`Converse`) vs leave as `tool_use_id`. Default: leave as-is.
