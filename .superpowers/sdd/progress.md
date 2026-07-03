# MIM-50 AgentCore Long-Run Posture — SDD Progress Ledger

Workspace: .claude/worktrees/rma-ci-pipeline (jj). Base: main ebfb20db + spec 6ee7c808 + plan 50175524.
Spec: docs/superpowers/specs/2026-07-02-agentcore-long-run-posture-design.md
Plan: docs/superpowers/plans/2026-07-02-agentcore-long-run-posture.md

## Tasks
- [x] Task 1: streaming transport + idle timeout
- [ ] Task 2: on_event ordering contract
- [ ] Task 3: budget knobs on the wire
- [ ] Task 4: provider threading
- [ ] Task 5: Session live delivery + skip-batch
- [ ] Task 6: docs + CHANGELOG
- [ ] Task 7: QA sweep + canary extension

## Log
Task 1: complete (commit 31e123e0, review clean — Spec ✅ / Approved). Suite 191. Minor recorded: stream_reducer ++ accumulation is O(n²) in event count — flip to prepend+reverse if event counts grow. Deviation accepted: Bypass.pass/1 in stall test (documented API for intentional client-side disconnect).
