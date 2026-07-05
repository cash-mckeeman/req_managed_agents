# MIM-79 Consolidation Architecture — mimir extraction, RMA agent management, biai split

**Date:** 2026-07-04
**Status:** Design — ratified in session; decomposes into sub-projects, each with its own implementation plan
**Linear:** MIM-79 (umbrella). Related: MIM-75 (shipped routing release), MIM-74 (transport-clean guard), MIM-43 (aws_event_stream precedent), MIM-77 (mimir-ui consumer), MIM-62 (fpanda session seam), RMA GH #31 (outcomes)
**Repos:** req_managed_agents (this repo), mimir-gateway, biai-managed-agents, biai-platform, elixir-graph, + new `mimir` repo
**Binding prior art:** `mimir-gateway` `docs/planning/2026-07-04-rma-local-provider-and-session-gaps.md` (the RMA local-provider position doc — currently only in the `rma-local-design` worktree; committing it to gateway main is folded into SP1)

---

## 1. Decisions ratified in this brainstorm

1. **One architecture spec** (this document) settles the cascading decisions; each sub-project gets its own plan at execution time.
2. **biai-managed-agents survives as a thin `biai_agents` library** (domain agents + tools + knowledge backends + StepRunner). It does not merge into biai-platform; heavy deps (DuckDB, Draco venv, embeddings) stay out of the platform app.
3. **The extracted core is a new standalone repo: hex package `mimir`, namespace `Mimir`.** The name was deliberately re-examined: Mímir's mythology maps to the design — the head Odin carries and consults (the embeddable oracle, consulted in-process by every carrier) and the eye paid at the well (metered access to intelligence). The gateway remains `mimir-gateway`: the well, where the fleet drinks and pays. Hex name verified free (2026-07-04).
4. **Inner-loop governance integrates by composition, not dependency** (Approach A + the `Mimir.Sessions` amendment, §6). RMA never depends on `mimir`, `mimir` never depends on RMA; the canonical integration recipe lives in `mimir` as data-producing functions targeting RMA's stable, plain-data hook contract.
5. **All three MIM-75 carry-ins are in scope:** api_key threading (RMA 0.6.0), metadata passthrough (RMA 0.6.0), mimir-less mode (documented posture of the `mimir` lib, §4).
6. **Outcomes (RMA GH #31) slots into RMA 0.5.0** (§7): native `user.define_outcome` support on the CMA provider; no AgentCore equivalent exists (verified 2026-07-04 — AgentCore Evaluations is trace-level, out-of-session).

## 2. Target architecture

```
biai-platform (app: UI, storage impls, domain features)
 └─> biai_agents (thin lib: 4 domain agents + tools/knowledge + StepRunner)
      ├─> req_managed_agents   agents + environments + sessions, provider-agnostic
      │     ├─ req_llm          (optional dep — Local provider only)
      │     └─ aws_event_stream (optional dep — AgentCore only)
      └─> mimir                 pure lib: oracle, pricing, decision vocabulary,
                                RouterClient, Guard/Ingest/Sessions
elixir-graph (app)
 ├─> req_managed_agents   (diverged inline ManagedAgents.* copy deleted)
 └─> mimir
mimir-gateway (service: fleet state, multi-tenant edge, paid hosting)
 ├─> mimir                (adopts the lib, deletes its duplicated modules)
 └─> req_managed_agents   (hosts sessions in-process, meters + governs)
```

### Invariant rules

1. **RMA never depends on `mimir`** — not even optionally. Governance reaches RMA sessions through two neutral seams only: `model_config` (granted key + routed base_url → data-plane hard enforcement at the gateway's Postgres constraint) and `turn_guard`/`handle_event` (host-composed policy → control-plane soft enforcement/observability).
2. **`mimir` never depends on RMA** — pure vocabulary + math + a Req-based HTTP client. No Ecto, no Phoenix, no OTP state beyond TurnEvents' ETS.
3. **Composition happens in the embedder** — StepRunner (`biai_agents`), gateway `Core.run_agent`, elixir-graph, any app — via the single canonical `Mimir.Sessions` recipe (§6). One core, three-plus embedders, zero cross-deps between the libraries.

### Why mechanism/policy separation (recorded rationale)

RMA answers *how* (define/provision/run an agent on any runtime; churn tracks provider APIs). mimir answers *whether/where/at-what-cost* (churn tracks pricing, policy, product). Both are public; each has consumers that legitimately want it without the other. The seam between them is narrow and stable (a map into `turn_guard`, raw event maps into `handle_event`, a keyword list of opts out of `Mimir.Sessions`), so merging buys one keyword of ergonomics and costs a version pin between two fast-moving public libraries plus a doubled optional-dep test matrix in RMA.

**Agents-as-managed-entities does open a governance door — what walks through it is identity, not enforcement.** Content-addressed agent identity (spec digest, §5 RMA 0.7.0) becomes shared *vocabulary*: `Mimir.Descriptor`/`Mimir.DecisionRecord` grow agent-identity fields, and RMA carries them as correlation metadata — strings crossing the seam as data, exactly like `mimir_request_id` today. Even per-turn re-placement mid-session (future) fits the same shape: a between-turn hook where the host consults the oracle and RMA executes the answer. If a concrete case ever needs more than data across the seam, `{:mimir, optional: true}` in RMA is an additive, non-breaking escalation; the reverse (removing a shipped optional integration) is breaking. The reversible door stays open; we do not walk through it now.

## 3. The `mimir` library (new repo)

### Moves from mimir-gateway (all pure or ETS-only today)

| Gateway module | Becomes | Notes |
|---|---|---|
| `Router.Descriptor` | `Mimir.Descriptor` | + agent-identity fields (agent digest, name/version); + outcome-mode budget hint (§7) |
| `Router.Oracle` | `Mimir.Oracle` | pure filter-then-rank, unchanged |
| `Router.Catalog` | `Mimir.Catalog` | config-driven entries |
| `Router.Snapshot` | `Mimir.Snapshot` | struct + `assemble` with explicit inputs; the gateway wires its own health/pricing sources |
| `Router.Health` | `Mimir.Health` | ETS lane health |
| `Router.DecisionRecord` | `Mimir.DecisionRecord` | + agent identity |
| `Router.RouteLog` (pure builder half) | `Mimir.RouteLog` | `to_meta/2` and friends; persistence stays with the embedder |
| `Pricing` + vendored LiteLLM DB + `mix mimir.pricing.refresh` | `Mimir.Pricing` | the single pricing oracle for every repo |
| `TurnEvents` + `TurnEvents.GenAi` | `Mimir.TurnEvents` | ETS table names + config namespace parameterized |
| `RouterClient` behaviour + `HTTP` impl | `Mimir.RouterClient` | biai's deliberately-duplicated T8 mirror deletes |
| `RequestLog.Redact` | `Mimir.Redact` | pure masking |

Config moves to the `:mimir` namespace (`:mimir, :catalog`, `:mimir, :pricing`, `:mimir, :pricing_db_path`).

### New composition modules (mimir 0.2.0, §6)

`Mimir.Guard`, `Mimir.Ingest`, `Mimir.Sessions`.

### Stays in mimir-gateway

VirtualKeys, Grants, Ledger, RequestLog persistence, `Router.Tree`, `Router.Pipeline` + `RouterClient.InProcess` (they mint grants — fleet state), all controllers/plugs/providers/dispatch. Enforcement remains a *capability* backed by the `spent_not_over_budget` Postgres constraint. The gateway becomes `mimir`'s first embedder: takes the dep, deletes its copies, keeps its 319-test suite green as the adoption gate.

### Mimir-less (gateway-less) mode — supported posture

A single-app deployment embeds the lib directly: config catalog, degenerate snapshot (all lanes healthy, config pricing), `Mimir.Oracle.decide/4` in-process, no grants (no fleet state), budget expressed as a plain `Mimir.Guard` cap instead of a minted key. Same descriptors, same decision records, no service required. Documented in the lib README with a worked example.

## 4. RMA release train

Extends the ratified position doc's train (0.4.1/0.5.0/0.6.0) by one release; the doc's decisions are binding and not restated in full here.

| Release | Content |
|---|---|
| **0.4.1** (patch) | AgentCore timeout-cancel fix: on sync-run timeout, shut down the poll Task so Finch tears down the HTTP stream; document server-side `timeoutSeconds` as the authoritative server budget. |
| **0.5.0** (minor) | Session-level additions, one PR per concern: (a) terminal-tool enforcement — `require_terminal_tool: true` + `max_reprompts` (default 2), exhausted re-prompts finish `stop_reason: :no_terminal_tool`; (b) **`turn_guard`** — `fn %{usage: map, turns: n, session_id: id} -> :cont | {:halt, reason} end` invoked after each turn's accumulate; on halt: `:terminated` SessionResult, `{:error, {:halted, reason}}`. **This freezes the governance hook contract — plain data in, plain verdict out;** (c) `rma.text_delta` normalized deltas (additive, alongside raw events, every provider); (d) **outcomes (GH #31)** — `Event.define_outcome/3` + `:outcome` option on `Session.run/start_link`, honored natively by the CMA provider's `kickoff_input` (`:outcome` and `:prompt` mutually exclusive, outcome wins), `{:error, :outcome_unsupported}` on AgentCore/Local; optional `Session.send_event/2` for `user.tool_confirmation` and mid-session events. Terminal semantics per the issue's note: only `status_idle` (`satisfied` / `max_iterations_reached` / `failed`) is terminal; `span.outcome_evaluation_end` with `needs_revision` is not — test that explicitly. |
| **0.6.0** (minor) | `Providers.Local` per the position doc (`mode: :request_response`, chat_fun seam, `local.*` event namespace, loop guards relocated from biai's Core.Runner: dedup short-circuit, consecutive-error correctives, final-turn directive, MIM-34 retry) + optional `req_llm` dep (ex_aws_auth raise-at-first-use pattern) + README repositioning ("one Session loop, any loop host") + **carry-in: api_key threading** (canonical `:api_key` in model_config → chat_fun auth; also honored by CMA/AgentCore client construction where applicable) + **carry-in: metadata passthrough** (model_config `:metadata` carried into telemetry metadata and `handle_event` context end-to-end on every provider, so decision-correlated ingestion works uniformly). |
| **0.7.0** (minor) | **Agent management — the MIM-79 headline.** Agents become first-class managed entities exactly like environments: `%ReqManagedAgents.Agent.Spec{}` (name, system_prompt, tools, terminal_tool, model_config defaults) → content-addressed digest identity; provision-if-absent through the existing `Provisioner`/`Store` machinery (formalizing the Managed adapter's ad-hoc ETS spec-hash cache); per provider: CMA `create_agent` server-side, AgentCore harness reference, Local identity. The run-lifecycle behaviour absorbed from biai: `ReqManagedAgents.Agent` (`setup/2`, `finalize/3`, `teardown/1`, `registry/0`, `model/1`, `runner_opts/2` — signatures reconciled with `Session` opts at plan time). `ReqManagedAgents.run(agent, opts)` becomes the single entry; provider selection is an option, and the biai Adapter layer's job dissolves into it. Agent digests flow into telemetry/metadata for decision-record correlation (§2). |

0.7 lands after 0.6 because the Agent behaviour wants Local underneath it (otherwise SelfManaged must be shimmed twice).

## 5. mimir release train

| Release | Content |
|---|---|
| **0.1.0** | The extraction (§3 table) ported with its unit tests (pure modules move nearly verbatim); gateway adopts the dep, deletes its copies; 319-test gateway suite green is the integration gate. Housekeeping: commit the RMA position doc from the `rma-local-design` worktree to gateway main. |
| **0.2.0** | Composition layer, gated on RMA 0.5.0 freezing the hook contract: **`Mimir.Guard`** (`for_grant(grant, model, opts) :: turn_guard_fun` — prices accumulated usage via `Mimir.Pricing`, halts on budget breach; also plain caps for mimir-less mode), **`Mimir.Ingest`** (wraps a Handler; maps raw session events + `rma.text_delta` into decision-correlated gen_ai vocabulary via `Mimir.TurnEvents`), **`Mimir.Sessions`** (`opts(route_response, opts \\ []) :: keyword` — the ONE canonical recipe: granted key + routed base_url into `model_config`, guard from the grant, ingest wrap with decision_id/metadata passthrough). Contract targets: RMA's documented plain-data hooks only — no RMA types imported. |

## 6. Governance composition (the seam, precisely)

```elixir
# any embedder — StepRunner, gateway Core.run_agent, elixir-graph, your app:
{:ok, resp} = Mimir.RouterClient.route(descriptor, client_opts)   # or Oracle.decide in mimir-less mode
Session.run(provider, Mimir.Sessions.opts(resp) ++ [handler: MyTools, ...])
```

- Data plane (hard): granted child key + routed base_url in `model_config` → the gateway's Postgres constraint rejects over-budget spend. Unchanged from MIM-75.
- Control plane (soft): `Mimir.Guard` meters per-turn usage against the grant as it accumulates and halts runaway sessions (`{:halt, {:budget_exceeded, usage}}`); `Mimir.Ingest` emits decision-correlated gen_ai events for MIM-77's swimlanes. This closes the opaque-inner-loop gap for CMA/AgentCore where the gateway cannot sit in the data plane.
- Crash reconciliation stays post-hoc: a session that dies mid-turn reports partial spend through provider session logs; importing those is gateway-side work, out of scope here, unblocked by the same event vocabulary.

Error handling: `Mimir.Sessions.opts/2` raises on a malformed route response (missing grant/placement) — fail at composition time, not mid-session. `Mimir.Guard` never raises mid-run; on pricing-lookup miss it degrades to token-cap-only and emits a telemetry warning.

## 7. Outcomes spike (RMA GH #31) — findings and slotting

- **CMA:** `user.define_outcome` (description + rubric + `max_iterations`) runs a **server-side grade→revise loop**; the session is terminal only at `status_idle` with `satisfied` / `max_iterations_reached` / `failed`. The issue's comment thread carries an implementation-ready design (Event builder + `kickoff_input` honor + terminal-semantics test); it slots into **RMA 0.5.0** (§4).
- **AgentCore: no in-session equivalent exists** (verified 2026-07-04). AgentCore Evaluations (GA 2026-03) is rubric-based LLM-as-judge scoring of *traces* — online sampling + on-demand/CI batch — an out-of-session quality plane, extended by the optimization loop (recommendations, A/B, batch eval) at deployment level. Different archetype, not a different flavor of the same feature. RMA therefore returns `{:error, :outcome_unsupported}` on AgentCore/Local; client-side emulation (judge + re-drive over the 0.5.0 re-prompt machinery) is a deferred option, not scheduled.
- **Governance note:** an outcome session is a spend multiplier — up to `max_iterations` server-side revisions inside one session. This is exactly the opaque-inner-loop shape `turn_guard`/`Mimir.Guard` caps, and `Mimir.Descriptor` gains an outcome-mode hint so the oracle can scale `budget_ceiling_microdollars` the way `fanout_hint` scales for width (exact field shape decided in the mimir 0.1.0/0.2.0 plans).

## 8. Consumer migrations

- **biai-managed-agents → `biai_agents`** (after RMA 0.6/0.7, own PR train): flip `Adapter.SelfManaged` onto `Providers.Local` (acceptance: business_analyst 4/6 eval gate + QA checkpoint fingerprints — the bar the AgentCore slim-down cleared); migrate the four domain agents onto `ReqManagedAgents.Agent` (FPanda last — it drives Core.Runner directly today; MIM-62 retargets it at `Session.start_link` + `message`); delete `Core.Runner` + `runner/` + `core/loop.ex`, the byte-identical `Handler` mirror, the Adapter layer, and the T8 `RouterClient` mirror (→ `Mimir.RouterClient`); StepRunner remains here as the composition site, switched to `Mimir.Sessions.opts/1`. What remains is the thin lib.
- **elixir-graph:** delete the diverged inline `ManagedAgents.*` copy; agents implement `ReqManagedAgents.Agent`; deps on RMA + mimir directly.
- **mimir-gateway:** adopts `mimir` (SP1); `Core.run_agent` swaps hand-rolled metering for `Mimir.Sessions`/`Guard` like every other embedder (its `Core.log_completion` bare-map cleanup rides the same change — the RouteLog typed-struct precedent applies).

## 9. Sequencing

```
Track A (mimir):  SP1 extract lib 0.1.0 + gateway adopts ────────────┐
Track B (RMA):    SP2 0.4.1 → SP3 0.5.0 → SP4 0.6.0 ─────────────────┤
                                                          ┌──────────┘
                  SP5 mimir 0.2.0 (Guard/Ingest/Sessions)
                → SP6 RMA 0.7.0 (agent management)
                → SP7 biai split → SP8 elixir-graph dedup
```

Tracks A and B are independent (different repos, no shared files) and can run as parallel work streams. Each SP gets its own implementation plan (superpowers:writing-plans) and, where multi-commit, its own jj workspace per the global workspace-isolation rule.

## 10. Testing & acceptance gates

- **mimir 0.1.0:** ported unit tests green in the new repo; gateway suite (319 tests, seeds 0 + 12345, warnings-as-errors) green after adoption.
- **RMA releases:** per the position doc — scripted chat_fun unit tests for Local's callback mapping, stub-provider Session tests for turn_guard/terminal-reprompt/outcome-terminal-semantics, one `:external`-tagged Ollama live test; CHANGELOG discipline per release.
- **SP7 end-to-end canary:** route → grant → `Providers.Local` with chat_fun through a mimir lane → data-plane enforcement + `Mimir.Guard` soft-halt + decision-correlated events visible in the workflow tree. This is the whole-architecture proof, analogous to MIM-75's T9 canary.
- **biai flips:** existing eval gates (business_analyst 4/6, QA fingerprints).

## 11. Out of scope

- `jido_managed_agents` server arm (parallel P2a track, unchanged).
- MCP, structured output (no current agent needs them).
- Pricing tables, virtual keys, or any mimir type in RMA (§2 invariants).
- Session-log post-hoc import into the gateway (unblocked by, not part of, this arc).
- mimir-ui (MIM-77) — consumer of the resulting observability, separate arc.
- AgentCore client-side outcome emulation (§7, deferred).
