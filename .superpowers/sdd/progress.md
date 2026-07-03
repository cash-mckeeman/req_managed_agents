# MIM-50 AgentCore Long-Run Posture — SDD Progress Ledger

Workspace: .claude/worktrees/rma-ci-pipeline (jj). Base: main ebfb20db + spec 6ee7c808 + plan 50175524.
Spec: docs/superpowers/specs/2026-07-02-agentcore-long-run-posture-design.md
Plan: docs/superpowers/plans/2026-07-02-agentcore-long-run-posture.md

## Tasks
- [x] Task 1: streaming transport + idle timeout
- [x] Task 2: on_event ordering contract
- [x] Task 3: budget knobs on the wire
- [x] Task 4: provider threading
- [x] Task 5: Session live delivery + skip-batch
- [x] Task 6: docs + CHANGELOG
- [x] Task 7: QA sweep + canary extension

## Log
Task 1: complete (commit 31e123e0, review clean — Spec ✅ / Approved). Suite 191. Minor recorded: stream_reducer ++ accumulation is O(n²) in event count — flip to prepend+reverse if event counts grow. Deviation accepted: Bypass.pass/1 in stall test (documented API for intentional client-side disconnect).
Task 2: complete (commit f0efb82d, review clean — Spec ✅ / Approved, verbatim tests, no lib changes). Suite 193.
Task 3: complete (commit 7f3f086a, review clean — Spec ✅ / Approved, verbatim tests, no lib changes). Suite 195. (Reviewers note the ledger updates lag one commit — administrative artifact of controller bookkeeping, expected.)
Task 4: complete (commit 5111c81d, review clean — Spec ✅ / Approved). Suite 197. Minor recorded (brief-level): second test name "…and on_event still targets the subscriber" overstates its body (only budgets-nil is asserted there) — candidate rename at final review.
Task 5: complete (commit f3a45ec6 after alias-trim squash, review clean — Spec ✅ / Approved; FIFO exactly-once verified, clause order checked). Suite 200. Minor recorded: envelope_type/1 silent on empty/multi-key maps (unreachable today) — candidate comment note at final review.
Task 6: complete (commit 6df4aec0, review clean — Spec ✅ / Approved; ⚠️ Task-4 moduledoc line resolved by controller from Task 4 review). Docs gate clean, suite 200. Minors recorded: Session moduledoc "total cost" phrasing; :idle_timeout default not restated in Session moduledoc — candidates at final review.
Task 7: complete (commit 15d399c2, review clean — Spec ✅ / Approved; accumulate_ok_chunk extraction verified pure code-motion). Gates: format/test(200)/docs/dialyzer/hex.build PASS; plain `mix credo` (the CI gate) no issues; credo --strict has 12 pre-existing findings in untouched files (main baseline — possible follow-up ticket).
ALL 7 TASKS COMPLETE. Pending: final whole-branch review.
