# RMA Public-Repo Hygiene Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove internal tracker naming (`MIM-…`, internal phase tags like `P2a`/`P2b`) from every consumer-visible surface of req_managed_agents — source comments, test names, CI config, and retroactively all GitHub PR titles/bodies — while keeping the PR-body `Closes MIM-…` lines that drive tracker automation.

**Architecture:** Three independent surfaces: (1) repo contents (one lib comment + ~11 test-file occurrences + one CI workflow comment) — a comment/name-only change shipped as a patch release; (2) GitHub PR metadata, edited retroactively via `gh pr edit` (merged git history is NOT rewritten); (3) the `docs/` tree, which needs a user decision before touching (internal working docs vs public surface).

**Tech Stack:** grep, `gh` CLI, jj. No code behavior changes anywhere in this plan.

**Timing:** runs after the 0.4.1 release plan and before the 0.5.0 release starts. If 0.4.1 has not shipped yet when this runs, fold Task 1's source scrub into the 0.4.1 release instead of cutting 0.4.2.

## Global Constraints

- **Version control is jj, not git.** Commit with `jj describe -m "<message>" && jj new`. Never `git add/commit/push`. Use `--git` on any `jj diff`/`jj show`.
- **The rule being enforced (and obeyed by this plan's own commits/PR):** internal tracker identifiers never appear in commit messages, code, comments, test names, moduledocs, README, CHANGELOG, or PR titles. The ONLY permitted tracker reference is the PR body's trailing `Closes MIM-…` (or `Part of MIM-…`) line — those lines drive auto-link/auto-close and MUST be preserved on every existing PR.
- **Never rewrite merged git history.** Old commit messages keep their tracker ids; only PR titles/bodies (mutable metadata) are edited retroactively.
- **No behavior changes.** Every diff in Task 1 is comments, test names, and doc strings; the test suite must pass unchanged (same assertions, renamed tests only).
- Scrub rule: delete the tracker token and keep the descriptive remainder; when the token *was* the description, replace it with the behavior description (exact replacements below). Never delete the surrounding fact — these comments carry live-verified wire knowledge.

---

### Task 1: Source scrub (lib, test, CI) + patch release

**Files:**
- Modify: `lib/req_managed_agents/agent_core/client.ex:27`
- Modify: `test/req_managed_agents/session_live_events_test.exs:5`, `test/req_managed_agents/providers/bedrock_agent_core_test.exs:110,333,335`, `test/req_managed_agents/agent_core/event_stream_test.exs:62`, `test/req_managed_agents/agent_core/client_stream_test.exs:47,66`, `test/req_managed_agents/agent_core/converse_test.exs:115,122`, `test/live/live_smoke_test.exs:264,436`
- Modify: `.github/workflows/live-canary.yml:4`
- Modify: `mix.exs:4` + `CHANGELOG.md` (patch release — see Step 4)

**Interfaces:**
- Produces: `grep -rn "MIM-" lib/ test/ priv/ examples/ README.md CHANGELOG.md mix.exs .github/` returns nothing — the gate every later release re-runs.

- [ ] **Step 1: Apply the replacements**

Line numbers are as of `v0.4.0` — re-locate with grep if they drifted. Occurrence table (keep everything else on each line/name intact):

| Location | Current fragment | Replacement |
|---|---|---|
| `lib/…/agent_core/client.ex:27` | `# Inter-chunk idle timeout for the streaming data plane (spec: MIM-50 design §3).` | `# Inter-chunk idle timeout for the streaming data plane.` |
| `session_live_events_test.exs:5` | comment fragment `post-MIM-50):` | reword the sentence to drop the token, e.g. `(live provider events):` — keep the rest of the comment's meaning |
| `bedrock_agent_core_test.exs:110` | `test "MIM-52 regression: a reused contentBlockIndex recovers BOTH distinct tools"` | `test "regression: a reused contentBlockIndex recovers BOTH distinct tools"` |
| `bedrock_agent_core_test.exs:333` | section comment `# ── MIM-50 long-run threading ──…` | `# ── long-run threading (per-invocation budgets) ──…` |
| `bedrock_agent_core_test.exs:335` | `describe "MIM-50 long-run threading" do` | `describe "long-run threading (per-invocation budgets)" do` |
| `event_stream_test.exs:62` | `# A real AgentCore early-termination frame (confirmed live, MIM-52 spike):` | `# A real AgentCore early-termination frame (confirmed live):` |
| `client_stream_test.exs:47` | `test "MIM-50: a turn longer than idle_timeout succeeds …"` | `test "a turn longer than idle_timeout succeeds …"` (keep the rest verbatim) |
| `client_stream_test.exs:66` | `test "MIM-50: a stream that stalls beyond idle_timeout …"` | `test "a stream that stalls beyond idle_timeout …"` (keep the rest verbatim) |
| `converse_test.exs:115` | `# MIM-52 fix. \`parse/1\` accumulates tool blocks …` | `# \`parse/1\` accumulates tool blocks …` |
| `converse_test.exs:122` | `describe "tool-use id uniqueness (MIM-52)" do` | `describe "tool-use id uniqueness" do` |
| `live_smoke_test.exs:264` | `# MIM-50: exercise the per-invocation server budgets + a generous idle guard` | `# Exercise the per-invocation server budgets + a generous idle guard` |
| `live_smoke_test.exs:436` | `# MIM-65: the opaque environment pass-through, sessionStorage = the no-VPC mount.` | `# The opaque environment pass-through, sessionStorage = the no-VPC mount.` |
| `.github/workflows/live-canary.yml:4` | `… (see MIM-52,` and any continuation | reword the sentence to state the fact without ticket refs (e.g. `# Both are beta surfaces that change under us.`) — read lines 1–10 first and keep the rest of the comment |

- [ ] **Step 2: Run the gate**

Run: `grep -rn "MIM-\|P2a\|P2b" lib/ test/ priv/ examples/ README.md CHANGELOG.md mix.exs .github/`
Expected: no output. (`docs/` is deliberately NOT in this gate — Task 3.)

- [ ] **Step 3: Run the suite**

Run: `mix test`
Expected: same pass count as before the scrub — renames only, zero assertion changes.

- [ ] **Step 4: Patch release**

If 0.4.1 has already shipped: bump `mix.exs` to `@version "0.4.2"` and add above the previous entry in `CHANGELOG.md`:

```markdown
## v0.4.2 (<today's date>)

### Changed
- Internal housekeeping: source comments and test names no longer reference
  internal tracker ids. No behavior, API, or documentation changes.
```

If 0.4.1 has NOT shipped yet: skip the extra bump — this commit rides the 0.4.1 release and its CHANGELOG entry gains the same line.

- [ ] **Step 5: Commit**

```bash
jj describe -m "chore: strip internal tracker ids from source comments, test names, CI config

Comment/name-only sweep; no behavior change. Tracker linkage lives only in
PR-body closing lines from here on." && jj new
```

---

### Task 2: Retroactive PR title/body scrub (GitHub metadata)

**Files:** none in-repo — `gh pr edit` against `cash-mckeeman/req_managed_agents`.

**Interfaces:**
- Consumes: the inventory commands below (18 titles, 27 bodies carry tracker ids as of 2026-07-04).
- Produces: no PR title contains a tracker id; PR bodies keep ONLY their trailing `Closes MIM-…` / `Part of MIM-…` lines; every edited PR still shows its Linear attachment (spot-check).

- [ ] **Step 1: Take a fresh inventory (numbers may have grown)**

```bash
gh pr list --repo cash-mckeeman/req_managed_agents --state all --limit 200 \
  --json number,title --jq '.[] | select(.title | test("MIM-|P2a|P2b")) | "\(.number)\t\(.title)"'
```

- [ ] **Step 2: Retitle — exact mapping for the 18 known PRs**

Rules applied: strip `MIM-xx: ` prefixes and ` (MIM-xx)` / ` — MIM-xx` suffixes; replace internal phase tags (`P2a`, `P2b`) with nothing or a conventional type prefix when the tag was load-bearing.

| PR | New title |
|---|---|
| 49 | `feat(provisioner): declared runtimes + v0.4.0 — spike-proven mise bootstrap` |
| 48 | `feat(provisioner): environments as content-addressed images — ensure/tag/resolve/prune` |
| 47 | `feat(provisioner): pluggable Store — ETS default, persistent Store.File` |
| 39 | `feat(agent_core): environment + command API + SessionStorage artifacts — v0.3.0` |
| 38 | `feat(artifacts): Artifacts vocabulary + ClaudeFiles store + files primitives` |
| 35 | `feat(session): SessionInfo to handlers at call time` |
| 25 | `feat(agent_core): streaming liveness long-run posture` |
| 22 | `docs(ci): canary-validated AWS reference — the real permission ladder` |
| 21 | `feat(ci): OIDC-scoped AWS resources for the live canary; cheap models` |
| 16 | `feat: struct result vocabulary + token usage` |
| 11 | `refactor(agent_core): delegate EventStream framing to aws_event_stream` |
| 10 | `fix(converse): key tool blocks by toolUseId, route deltas by active index` |
| 9 | `feat(agent_core): exception-frame surfacing + streaming hardening` |
| 8 | `feat(otel): ReqManagedAgents.OpenTelemetry — gen_ai.* bridge` |
| 5 | `fix(agent_core): live-validated AgentCore wire fixes (host split, systemPrompt, event-type tagging)` |
| 4 | `fix(agent_core): reconcile AgentCore wire contract to GA bedrock-agentcore` |
| 3 | `feat(agent_core): AgentCore Harness provider for req_managed_agents` |
| 2 | `feat: Profile seam + ToolSchema + Provisioner + polymorphic tool handler` |

One command per PR: `gh pr edit <N> --repo cash-mckeeman/req_managed_agents --title "<new title>"`.

- [ ] **Step 3: Scrub bodies (27 PRs), preserving the closing lines**

For each PR from `--jq '.[] | select(.body | test("MIM-")) | .number'`:
1. `gh pr view <N> --repo cash-mckeeman/req_managed_agents --json body --jq .body > /tmp/pr-<N>.md`
2. Edit the file: **keep** any trailing `Closes MIM-…` / `Part of MIM-…` line verbatim (these drive Linear auto-link/auto-close). For every OTHER tracker mention, reword the sentence to keep its meaning without the id (e.g. "the MIM-50 posture" → "the streaming-liveness posture"). Delete nothing but the ids.
3. `gh pr edit <N> --repo cash-mckeeman/req_managed_agents --body-file /tmp/pr-<N>.md`

- [ ] **Step 4: Verify**

```bash
# Titles: expect empty.
gh pr list --repo cash-mckeeman/req_managed_agents --state all --limit 200 \
  --json number,title --jq '.[] | select(.title | test("MIM-|P2a|P2b")) | .number'
# Bodies: every remaining MIM- mention is a Closes/Part-of line. Expect empty:
gh pr list --repo cash-mckeeman/req_managed_agents --state all --limit 200 \
  --json number,body --jq '.[] | select(.body | test("MIM-")) |
    select([.body | split("\n")[] | select(test("MIM-")) |
      test("^(Closes|Part of) MIM-") | not] | any) | .number'
```

Spot-check two edited PRs in Linear (issue attachments still present — editing a body re-triggers the linker; the kept closing line re-links if anything drops).

---

### Task 3: `docs/` tree — decide, then apply

**Files:** `docs/aws-ci-setup.md`, `docs/qa/*.md`, `docs/superpowers/specs/*.md`, `docs/superpowers/plans/*.md` (all carry tracker ids; two filenames do too).

- [ ] **Step 1: STOP — ask the user which posture `docs/` takes**

Present exactly these options and wait:
1. **Internal work-log carve-out** — `docs/qa/` + `docs/superpowers/` are declared internal working docs (tracker ids allowed there by policy); only `docs/aws-ci-setup.md` gets scrubbed. Cheapest; cross-references stay intact.
2. **Full scrub** — reword tracker ids out of every doc and rename the two offending files (`2026-06-29-mim43-…`, `2026-06-28-p2b-…`); accept that historical planning docs lose their tracker cross-refs.
3. **Relocate** — move `docs/qa/` + `docs/superpowers/` out of the public repo (e.g. to the private ops repo), leaving only consumer docs here.

- [ ] **Step 2: Apply the chosen option, commit**

```bash
jj describe -m "docs: <chosen posture> for internal working docs" && jj new
```

If option 1 is chosen, also add the carve-out line to this repo's contributing/README dev section so the policy is written down: "Internal planning docs under `docs/superpowers/` and `docs/qa/` may reference tracker ids; no other surface may."

---

### Task 4: QA-CHECKPOINT — sweep verification gate

**Files:**
- Create: `docs/qa/<run-date>-hygiene-sweep-manual-test.md` (house header; the runbook itself contains no bare tracker ids outside quoted grep output — refer to "the sweep issue" by its plan file)

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: the PASS verdict that closes the sweep. The 0.5.0 plan's precondition is THIS verdict, not merely "the tasks ran".

- [ ] **Step 1: Re-run every gate from a clean state and record real output**

| # | Check | Command | Expected |
|---|---|---|---|
| 1 | Source surface clean | `grep -rn "MIM-\|P2a\|P2b" lib/ test/ priv/ examples/ README.md CHANGELOG.md mix.exs .github/` | No output |
| 2 | Suite behavior unchanged | `mix test 2>&1 \| grep -E "^(Finished\|Result)"` vs the count recorded before Task 1 | Identical pass count (renames only) |
| 3 | Docs + package build | `mix docs && mix hex.build` | Clean; hexdocs carry no tracker ids (spot-check the generated `doc/` for "MIM-") |
| 4 | PR titles clean | Task 2 Step 4's title jq | Empty |
| 5 | PR bodies: only closing lines remain | Task 2 Step 4's body jq | Empty |
| 6 | Linear links survived the body edits | Open 3 edited PRs' issues in Linear (`get_issue` → `attachments`) | Each still shows its PR attachment |
| 7 | docs/ posture applied | Per the Task 3 decision | Matches the user's choice; if carve-out: the policy line is present in the contributing/README dev section |

- [ ] **Step 2: Verdict + commit**

Runbook ends with `RESULT: PASS — 7/7 checks`. Commit:

```bash
jj describe -m "qa: hygiene-sweep verification checkpoint (PASS)" && jj new
```
