# MIM-55 Result Vocabulary & Usage — Progress Ledger

Base: main @ 8eef2737. Branch: ryan/mim-55-...
Spec: docs/superpowers/specs/2026-07-01-rma-result-vocabulary-and-usage-design.md (760a06f5)
Plan: docs/superpowers/plans/2026-07-01-rma-result-vocabulary-and-usage.md (3dd3b64d)

## Tasks
- [x] Task 1: The five structs (TurnResult/SessionResult/Usage/ToolUse/ToolResult)
- [x] Task 2: Providers + behaviour + fakes speak structs (no usage yet)
- [x] Task 3: Token usage extraction (Claude events + Bedrock Converse metadata)
- [x] Task 4: Session assembles %SessionResult{}
- [x] Task 5: QA sweep (qa_checkpoint 7/7, qa_provisioning 2/2)

## Minor findings (for final review triage)
- T4: message/2 resets usage/tool_uses/turns but NOT events, so a follow-up message's SessionResult.events accumulates across messages (inconsistent per-message vs cumulative). Add events: [] to reset_acc for per-message consistency + a regression test.
- T2: bedrock_agent_core.ex — restore the dropped `# Harness built-in tools...` comment on server_tool_uses: [].
- T2: bedrock tool_use test no longer asserts `input` (Converse JSON-decode coverage gap) — restore an input assertion.

## Log
Task 1: complete (commit a01843be, review clean — Spec ✅ / Quality Approved; Provider.terminal() ⚠️ resolved: exists, clean compile). Suite 183.
Task 2: complete (commit 871e149c, review clean — Spec ✅ / Quality Approved; 2 Minors recorded; provider_test.exs result_of tests migrated too). Suite 183.
Task 3: complete (commit a1b9086e, review clean — Spec ✅ / Quality Approved; usage-shape assumption degrades gracefully to nil). Suite 186.
Task 4: complete (commit d86fa2a7, review clean — Spec ✅ / Quality Approved; ⚠️ resolved: parametrized loop covers both providers; events-reset Minor recorded). Suite 186 (both seeds).
Task 5: complete (no commit — captures worked unchanged). qa_checkpoint 7/7, qa_provisioning 2/2, suite 186 (both seeds).
Final whole-branch review (opus): CHANGES NEEDED → fixed (commit c835788d): I1 reset events on message/2 (+assertion); I2 max_turns delivers %SessionResult{} via shared builder; M2 doc/spec; M3i re-wrap; M4 ToolUse.input || %{}; restored Bedrock comment + input-through-Converse assertion. Residual minors: M1 Claude first-usage-event (documented assumption); M3ii text=terminal-turn not distinctly asserted (shared fake emits text: ""). Suite 186 (both seeds).
