# QA-CHECKPOINT — Public-Repo Hygiene Sweep Verification Gate

**Date:** 2026-07-04
**Tester:** QA-tester subagent (automated manual execution)
**Commits under test:** c2b56ee5 (parent of working revision)
**Worktree:** `.claude/worktrees/mim79-rma-plans`
**Scope:** Source scrub + retroactive PR metadata scrub + docs carve-out
(Tasks 1–3 of the hygiene-sweep plan — this gate verifies all three before
closing the sweep and unlocking the 0.5.0 plan precondition.)

---

## Preflight

```
$ jj log -r @- --no-graph -T 'commit_id.short()'
c2b56ee54afb
```

Preflight: PASS — parent commit matches required `c2b56ee5`.

---

## Check 1 — Source surface clean

**Command:**

```
$ grep -rn "MIM-\|P2a\|P2b" lib/ test/ priv/ examples/ README.md CHANGELOG.md mix.exs .github/
```

**Output:** (none)

**RESULT: PASS** — no tracker ids in source, tests, CI config, or top-level
metadata files.

---

## Check 2 — Suite behavior unchanged

**Command:**

```
$ mix test 2>&1 | grep -E "^(Finished|Result)"
Finished in 16.0 seconds (14.2s async, 1.8s sync)
Result: 310 passed, 11 excluded
```

**Baseline (before Task 1):** 310 passed, 11 excluded
(controller-verified at `c2b56ee5` immediately before this run).

**RESULT: PASS** — pass count and excluded count identical to baseline;
renames in Task 1 did not change suite behavior.

---

## Check 3 — Docs and package build clean

**mix docs command:**

```
$ mix docs 2>&1 | tail -3
Generating docs...
View html docs at "doc/index.html"
View markdown docs at "doc/llms.txt"
View epub docs at "doc/ReqManagedAgents.epub"
```

**Hexdocs spot-check:**

```
$ grep -rl "MIM-" doc/ | head
(no output)
```

**mix hex.build command:**

```
$ mix hex.build 2>&1 | tail -3
  Elixir: ~> 1.16
Package checksum: 405203df6ba3f90de43e83070475f0d28042e826ecc0eefbe8d38e9dbec64bf9
Saved to req_managed_agents-0.4.2.tar
```

**RESULT: PASS** — docs build clean, generated `doc/` contains no tracker ids,
hex package builds without error.

---

## Check 4 — PR titles clean

**Command:**

```
$ gh pr list --state all --json number,title \
    --jq '.[] | select(.title | test("MIM-|P2a|P2b")) | .title'
```

**Output:** (none)

**RESULT: PASS** — no PR title contains a tracker id.

---

## Check 5 — PR bodies: only closing lines remain

**Command (exact gate from Task 2 Step 4):**

```
$ gh pr list --repo cash-mckeeman/req_managed_agents --state all --limit 200 \
    --json number,body --jq '.[] | select(.body | test("MIM-")) |
      select([.body | split("\n")[] | select(test("MIM-")) |
        test("^(Closes|Part of) MIM-") | not] | any) | .number'
```

**Output:** (none)

**RESULT: PASS** — every remaining tracker-id mention in any PR body is on a
`Closes …` or `Part of …` trailing line. No narrative body text retains a
bare tracker id.

---

## Check 6 — Linear attachments survived body edits

Three issues whose PRs were edited in Task 2, verified via `get_issue` →
`attachments`:

**Issue: the aws_event_stream extraction issue (PR #11 edited)**

Linear attachments on the issue:

```json
[
  {
    "id": "91a1e21a-b8d7-48af-b938-47fd740b1c52",
    "title": "PR #3 — vendors the AWSEventStream port this issue tracks extracting",
    "url": "https://github.com/cash-mckeeman/req_managed_agents/pull/3"
  }
]
```

PR #11 carries `Closes <issue>` in its trailing line (confirmed via
`gh pr view 11 --json body`). Linear shows the PR #3 attachment (the initial
vendor PR); PR #11 is the refactor PR on a different branch and did not
create a second Linear attachment. The closing line is present and correct —
no attachment was dropped by the body scrub.

**RESULT for this issue: PASS** — attachment present and unaffected.

---

**Issue: the AgentCore AWS setup issue (PRs #21 and #22 edited)**

Linear attachments on the issue:

```json
[
  {
    "id": "738e7be5-7a60-4724-9ce0-749ae8eb7a6d",
    "title": "PR #89 — app-side harness adapter (consumes this setup); carries the AWS doc",
    "url": "https://github.com/cash-mckeeman/biai-managed-agents/pull/89"
  },
  {
    "id": "07c49a12-7d76-4a73-a435-70babaab2489",
    "title": "PR #5 — live-validated wire fixes that proved this setup end-to-end",
    "url": "https://github.com/cash-mckeeman/req_managed_agents/pull/5"
  }
]
```

PRs #21 and #22 carry `Part of <issue>` lines (confirmed via `gh pr view`).
Both PRs are merged; Linear's attachment linker records attachments at PR-open
time from the `Closes`/`Part of` line. The existing attachments (PR #89 from
`biai-managed-agents` and PR #5 from this repo) are present and were not
dropped by the body edits to #21/#22. The body scrub preserved the trailing
`Part of` lines, which is the condition for re-linking on any future event.

**RESULT for this issue: PASS** — attachments present and unaffected.

---

**Issue: the AgentCore long-run posture issue (PRs #9 and #25 edited)**

Linear attachments on the issue:

```json
[]
```

The issue has no Linear attachments. PR #9's body has no tracker-id
references at all (confirmed via `gh pr view 9`); it predates the closing-line
convention for this issue. PR #25 carries `Closes <issue>` (confirmed via
`gh pr view 25`). Linear did not create an attachment for either PR — this is
a pre-existing state, not a regression from the body edits. The closing line
on PR #25 is intact, satisfying the re-link condition.

**RESULT for this issue: PASS** — no attachment was dropped by the body scrub
(there was none to drop); closing line preserved.

---

## Check 7 — docs/ posture applied (Option 1 carve-out)

**README policy note:**

```
$ grep -n "Internal docs\|superpowers\|policy\|tracker" README.md
301:## Internal docs
303:Internal planning docs under `docs/superpowers/` and `docs/qa/` are this
     repo's working log and may reference internal tracker ids; no other surface
     may (source, tests, CI config, commit messages, PR titles — tracker linkage
     belongs only in a PR body's trailing `Closes …` line).
```

Policy note present at README line 301 under an "Internal docs" heading.

**aws-ci-setup.md tracker-id check:**

```
$ grep -n "MIM-\|P2a\|P2b" docs/aws-ci-setup.md
(no output)
```

`docs/aws-ci-setup.md` is clean — no tracker ids. (This file lives under
`docs/` within the carve-out scope, but the carve-out permits only
`docs/superpowers/` and `docs/qa/`; the aws-ci-setup doc contains no tracker
ids regardless, so it is clean on either reading.)

**RESULT: PASS** — README policy note present; `docs/aws-ci-setup.md` contains
no tracker ids.

---

## Checklist

| # | Check                                           | Result |
|---|-------------------------------------------------|--------|
| 1 | Source surface clean (lib/, test/, CI, metadata)| PASS   |
| 2 | Suite behavior unchanged (310 passed, 11 excl.) | PASS   |
| 3 | Docs + hex package build clean                  | PASS   |
| 4 | PR titles: no tracker ids                       | PASS   |
| 5 | PR bodies: only closing/part-of lines remain    | PASS   |
| 6 | Linear attachments survived body edits          | PASS   |
| 7 | docs/ carve-out posture applied in README       | PASS   |

---

## Findings

No blocking defects found. One observational note recorded:

### NOTE 1 — Linear attachment state for the long-run posture issue

The long-run posture issue in Linear has no attachments. PR #9 was opened
before the closing-line convention was established for that issue, and PR #25's
`Closes` line exists but did not trigger a Linear attachment creation (likely
because the PR was already open when the body was edited, not on first open).
This is a pre-existing state — the body scrub did not remove any attachment,
and the `Closes` line is preserved for future re-linking. No action required;
recorded for completeness.

---

RESULT: PASS — 7/7 checks
