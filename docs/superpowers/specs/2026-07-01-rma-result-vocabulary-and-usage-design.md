# RMA Result Vocabulary & Usage — Design

**Date:** 2026-07-01
**Status:** Design (approved in brainstorming; ready for implementation plan)
**Repo:** `req_managed_agents` · **Linear:** MIM-55

**Goal:** Give RMA a singular, consistent, struct-based result vocabulary, and surface the canonical
turn outcome + token usage that the loop already computes but currently discards.

**Context / gap:**
- `Session.run/2` returns a bare map `%{terminal, stop_reason, events}`. The per-turn `normalize/1`
  already computes `text` / `custom_tool_uses` / `server_tool_uses` — then the Session throws them
  away at the result boundary. A consumer wanting the final text or the tools called must re-parse
  raw events by hand (this is exactly what biai-managed-agents' `ResultMapper` does today).
- Token **usage** is exposed on no result/normalize surface. Claude usage rides on SSE events
  (`stream.ex` reads a `"usage"` key, into telemetry only); Bedrock usage isn't extracted at all
  (`Converse.parse` never touches `metadata.usage`).
- The vocabulary is an inconsistent mix of bare maps (`turn_outcome`, `custom_tool_use`,
  `custom_tool_result`, …). **Pre-alpha, effectively no consumers** — so this is the moment to make
  the API a clean, consistent set of structs rather than preserve the map shapes.

This is the RMA-side enabler for the biai adapter slim-down (MIM-39): once the result carries the
final text + tools + usage, biai's `ResultMapper` collapses to a field projection.

## Design decisions (settled in brainstorming)

1. **Accumulate across the run.** The run result's `usage` is **summed** over all turns,
   `custom_tool_uses`/`server_tool_uses` are **collected** across all turns, and `text` is the
   **final (terminal) turn's** assistant answer. (The terminal turn alone has no tool-uses and only
   the last leg's tokens — accumulation is what's useful.)
2. **Usage carries canonical AND raw.** `%Usage{input_tokens, output_tokens, raw}` — the stable
   summed integers a consumer branches on, plus the provider's usage object(s) verbatim for
   troubleshooting (same canonical-plus-raw philosophy as `stop_reason`).
3. **Both providers now.** Claude usage from its SSE events; Bedrock usage via *new* Converse
   `metadata.usage` extraction.
4. **The whole vocabulary is structs, not a mix of maps.** Only `events` stays a list of raw
   provider maps (raw-preservation — verbatim provider JSON).
5. **Two result structs, not one overloaded struct.** Providers produce a per-turn `TurnResult`;
   the Session assembles a whole-run `SessionResult`. Same value structs (`Usage`, `ToolUse`,
   `ToolResult`) throughout; `SessionResult` earns its identity with a run-level `turns` count.
6. **No backward-compatibility constraint** (pre-alpha, no consumers). Optimize for a clean API.

## The vocabulary

Five structs (each `@derive Jason.Encoder`), under the `ReqManagedAgents` namespace:

```elixir
# Provider.normalize/1 returns this — the canonical outcome of ONE turn.
%ReqManagedAgents.TurnResult{
  terminal:         :end_turn | :requires_action | :terminated,
  stop_reason:      term() | nil,          # raw provider value (map for Claude, string for Bedrock)
  text:             String.t(),            # this turn's assistant text
  custom_tool_uses: [ToolUse.t()],         # client-side (return-of-control) tool calls this turn
  server_tool_uses: [ToolUse.t()],         # server-side (observe-only) tool calls this turn
  usage:            Usage.t() | nil,       # this turn's usage
  events:           [map()]                # this turn's raw provider events (verbatim)
}

# Session.run/2 + message/2 deliver this — the accumulated outcome of the WHOLE run.
%ReqManagedAgents.SessionResult{
  terminal:         :end_turn | :requires_action | :terminated,   # the terminal turn's
  stop_reason:      term() | nil,          # the terminal turn's
  text:             String.t(),            # the terminal turn's assistant answer
  custom_tool_uses: [ToolUse.t()],         # collected across the run
  server_tool_uses: [ToolUse.t()],         # collected across the run
  usage:            Usage.t(),             # summed across the run
  turns:            non_neg_integer(),     # run-level: loop iterations taken
  events:           [map()]                # all raw provider events (verbatim)
}

%ReqManagedAgents.Usage{
  input_tokens:  non_neg_integer(),        # summed
  output_tokens: non_neg_integer(),        # summed
  raw:           [map()]                   # per-turn provider usage objects, verbatim
}

%ReqManagedAgents.ToolUse{id: String.t(), name: String.t(), input: map()}

%ReqManagedAgents.ToolResult{tool_use_id: String.t(), text: String.t(), is_error: boolean()}
```

`TurnResult` and `SessionResult` share the same *value* types; the split makes the behaviour
boundary explicit — **providers produce per-turn `TurnResult`s, the Session assembles the
`SessionResult`** — and removes the "same struct means two different things" overload.

## Provider behaviour changes

- `@callback normalize([event()]) :: TurnResult.t()` (was the `turn_outcome` map).
- `@callback resume_input([ToolUse.t()], [ToolResult.t()]) :: input()` (was `custom_tool_use` /
  `custom_tool_result` maps).
- `@callback reconnect(...) :: {:ok, conn(), [ToolUse.t()], MapSet.t()} | {:error, term()}`
  (pending tool-uses are `ToolUse` structs).
- `Provider.result_of/2` returns a `%ToolResult{}` (was a `custom_tool_result` map).
- The `custom_tool_use` / `server_tool_use` / `custom_tool_result` map `@type`s are removed in
  favor of `ToolUse.t()` / `ToolResult.t()`.

Both providers' `normalize/1` build a `%TurnResult{}` with `%ToolUse{}` lists, a `%Usage{}`, and
raw `events` — **usage is the new extraction** (see below).

## Session accumulation

New Session state (folded once per turn, before the continue/finish branch): summed
`input_tokens`/`output_tokens`, the per-turn `usage.raw` list, and the collected
`custom_tool_uses` / `server_tool_uses`. `events` and `turns` are already accumulated.

- `handle_turn`: `tr = provider.normalize(turn_events)` → fold `tr.usage` + `tr.*_tool_uses` into
  the accumulators → branch on `tr.terminal`. Tools run on `tr.custom_tool_uses`, producing
  `[%ToolResult{}]` for `resume_input`.
- `finish` builds `%SessionResult{}` from the accumulators + the terminal `tr` (`terminal`,
  `stop_reason`, `text`) + `turns` + all `events`.
- **Live sessions:** `message/2` starts a fresh request — it resets the accumulators (with `turns`)
  so each message's `SessionResult` covers that message's response. On terminal, the `notify` pid
  receives the `%SessionResult{}` (consistent with `run/2`'s return) rather than a bare terminal
  atom.

## Usage extraction (wire shapes RECONCILED — no longer assumptions)

Reconciled 2026-07-01 against `req_llm`'s live provider parsers, real fixtures, biai-platform's live
CMA consumer, and the AWS/Anthropic docs:

- **Claude (`ClaudeManagedAgents.normalize`):** Managed Agents reports usage on **`span.model_request_end`**
  events under the **`model_usage`** key (fallback `usage`), Anthropic snake_case
  `input_tokens`/`output_tokens`. A turn may make several model requests, so **sum across all
  `span.model_request_end` events** in the turn; `raw` = the list of those usage objects. Confirmed
  against `biai-platform/lib/bizinsights/managed_agents/chat_handler.ex`.
  (Note the earlier assumption — a generic `"usage"` key — was WRONG; it would have yielded
  `usage: nil` on real runs. `stream.ex`/OTel telemetry reads the same wrong `"usage"` key and has
  the same bug — a follow-up for the telemetry path / MIM-47.)
- **Bedrock (`BedrockAgentCore.normalize` + `Converse`):** extract the Converse `metadata.usage`
  frame — camelCase `inputTokens` / `outputTokens` / `totalTokens` (+ optional `cacheRead/WriteInputTokens`).
  Consolidated (one object per response). Confirmed against `req_llm` `amazon_bedrock/converse.ex`
  + a real fixture. (Caveat: confirmed for plain Converse; not yet against a live *AgentCore Harness*
  `InvokeHarness` capture.)
- `usage.raw` is the **list** of per-turn provider usage objects; the canonical
  `input_tokens`/`output_tokens` are the summed integers. A turn with no usage → `TurnResult.usage`
  is `nil` and contributes nothing to the sum.
- **The `qa_provisioning` smoke asserts non-zero `usage.input_tokens`/`output_tokens`** through the
  real extraction path against real-shape events — a wire-shape mismatch fails the smoke.

## Facade / shim

`ReqManagedAgents.run_to_completion/1`, `start_session/1`, and `AgentCore.invoke_to_completion/1`
are unchanged call-sites — they return whatever `Session` returns, now a `%SessionResult{}`.

## Backward-compatibility

None required (pre-alpha, no consumers). The `qa_checkpoint` equivalence harness stays green: its
fingerprint reads `terminal`/`stop_reason`/`events` (a struct satisfies those map accesses) and
tool calls from the handler, none of which change — so the additive result stays **7/7** vs `main`.

## Files touched

- New: `lib/req_managed_agents/turn_result.ex`, `session_result.ex`, `usage.ex`, `tool_use.ex`,
  `tool_result.ex` (or a single `result.ex` defining all five — decide at plan time).
- `lib/req_managed_agents/provider.ex` — types + callback signatures + `result_of/2`.
- `lib/req_managed_agents/session.ex` — accumulation + `%SessionResult{}` + `notify`.
- `lib/req_managed_agents/providers/{claude_managed_agents,bedrock_agent_core}.ex` — `normalize`
  builds `%TurnResult{}` + usage.
- `lib/req_managed_agents/agent_core/converse.ex` — `metadata.usage` extraction.
- `lib/req_managed_agents/tools.ex` / callers — `%ToolResult{}` (as needed).
- Tests across the above; `qa/*` capture updated to the struct shape.

## Testing

- Per-provider `normalize` returns a `%TurnResult{}` with the right `%ToolUse{}` lists + `%Usage{}`
  (Claude from a usage-bearing event; Bedrock from a Converse `metadata.usage` frame).
- Session accumulation: a scripted multi-turn run yields a `%SessionResult{}` with summed
  `usage.input_tokens`/`output_tokens`, `usage.raw` = the per-turn list, collected tool-uses,
  `text` = the final turn's, and `turns` = the count.
- `qa_checkpoint` stays 7/7 (additive); the provisioning smoke + full suite stay green.

## Out of scope

- The biai-managed-agents `ResultMapper` slim-down (downstream consumer; MIM-39).
- Cost calculation from usage (mimir already prices; RMA only surfaces tokens).

## Open implementation questions (resolve during planning)

- The exact Claude event(s) that carry `usage` and the field names (`input_tokens`/`output_tokens`
  vs nested) — pin via extraction against the code/fixtures.
- The exact Bedrock Converse `metadata.usage` shape (`inputTokens`/`outputTokens`/`totalTokens`) and
  which frame carries it — pin against `Converse` + the AWS event model.
- One `result.ex` vs five files for the structs.
