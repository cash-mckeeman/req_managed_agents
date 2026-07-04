# RMA 0.3.0 Session Artifacts — SDD Progress Ledger

Workspace: .claude/worktrees/rma-030-artifacts (jj). Base: main 85fd3e88 + spec/plan/revision a89f6c84..52ef0463.
Spec: docs/superpowers/specs/2026-07-03-rma-030-session-artifacts-design.md
Plan: docs/superpowers/plans/2026-07-03-rma-030-session-artifacts.md (12 tasks, 3 PR phases, QA-CHECKPOINTs A/B/C)
Phase order: [P1] 1,2,QA-A,PR1 → [P2] 3,6,7,QA-B,PR2 → [P3] 4,5,8,9,[10 controller],11,QA-C,12,PR3

## Tasks
- [x] P1 Task 1: SessionInfo struct + SessionResult.session_id
- [x] P1 Task 2: threading (Handler/Tools/Session/Bedrock conn)
- [ ] P1 QA-CHECKPOINT A + PR 1 (pause for merge)
- [x] P2 Task 3: files primitives
- [x] P2 Task 6: Artifacts behaviour/facade
- [x] P2 Task 7: ClaudeFiles store
- [ ] P2 QA-CHECKPOINT B + PR 2 (pause for merge)
- [x] P3 Task 4: environment spec fields
- [x] P3 Task 5: CommandResult + command API
- [x] P3 Task 8: AgentCoreSessionStorage store
- [x] P3 Task 9: docs
- [x] P3 Task 10: IAM (controller)
- [x] P3 Task 11: canary legs
- [x] P3 QA-CHECKPOINT C
- [x] P3 Task 12: QA sweep + v0.3.0 + PR 3

## Log
P1 Task 1: complete (commit 6965d25d after controller rebase — implementer parented on main by mistake, repaired via jj rebase; review clean — Spec ✅ / Approved). Suite 203. Minor recorded (brief-level): SessionInfo JSON test does not assert provider key round-trip — candidate at PR-1 final review.
P1 Task 2: complete (commit a460d088 after nil→%SessionInfo{} test fix squash; review: Needs fixes → fix verified ✅ → Approved; all 13 spec items, dispatch/reconnect/backward-compat verified). Suite 206.
P1 PR 1 (#35): MERGED (main e8986b95). Workspace rebased; suite 208 green on new base.
── Phase 2 ──
P2 Task 3: complete (commit 03ed4c9e after controller rebase [second implementer-on-old-main incident — policy changed: sonnet floor + preflight base check] + controller-applied 2-line test-assertion fix from review; re-review Fix verified ✅ / Approved). Suite 211.
P2 Task 6: complete (commit 1543c628, preflight PASS, review clean — Spec ✅ / Approved; verbatim behaviour/facade, tight store_term vs store() typing). Suite 213.
P2 Task 7: complete (commit e69c52a6, preflight PASS, review clean — Spec ✅ / Approved; ISO-sort correctness + :not_found propagation + honest put-no-rollback verified; ⚠️ upload_file map shape resolved by controller — live canary uses same shape). Suite 219.
P2 PR 2 (#38): MERGED (main 867d456c) — after one CI credo --strict escape (single-<- with+else → case, controller-fixed, squashed; per-task gates now include credo --strict). Workspace rebased; suite 221 + strict credo green on new base.
── Phase 3 ──
P3 Task 4: complete (commit 4f27d754, preflight PASS, review clean — Spec ✅ / Approved, zero findings; opaque pass-through + hash-distinction proof verified). Suite 223, strict credo clean.
P3 Task 10 (IAM, controller): AWS half APPLIED with user approval — inline policy rma-ci-harness-lifecycle on rma-ci-github gained InvokeAgentRuntimeCommand + InvokeHarnessCommand (verified read-back, 18 actions). docs/aws-ci-setup.md line rides Task 9.
P3 Task 5: complete (commit 2b89f029, preflight PASS, review clean — Spec ✅ / Approved; two credo-driven extractions verified semantics-identical; brief JSON-escape typo fixed by implementer, validated by reviewer). Suite 228, strict credo clean. ARN-in-path SigV4 validation deferred to live canary (documented risk).
P3 Task 8: complete (commits 0b3b4e94 + fix 25b13631; review Approved with Important [base_path misclassified as library-controlled] → fixed: store/5 raises on quotes, comment corrected, temp-race doc note, raise test; fix diff controller-verified). Suite 235, strict credo clean. Minor recorded: chunk_every char-list round-trip (allocation nit) — final-review candidate.
P3 Task 9: complete (commit 67e7cbc7, preflight PASS, review clean — Spec ✅ / Approved, verbatim fidelity, handler moduledoc supersede judged correct; aws-ci-setup IAM line landed). Gates clean, suite 235.
P3 Task 11: complete (commit 188e9230, preflight PASS; 3 legs, tags + after-teardowns verified by controller; alias-order deviation cosmetic). 9 live excluded, suite 235, strict credo clean. Live behavior validated post-merge by canary.
P3 QA-CHECKPOINT C: complete (QA doc 8771d364, 25/26 + 1 finding wave; F1 code_bug [validate/1 accepted "."/".."] fixed + F2/F3/F4 test gaps closed in fc20abdf, controller-verified guard). Suite 238, strict credo clean.
P3 Task 12: complete (release stamp v0.3.0 + full gate: format/test(238)/credo-strict/docs/dialyzer/hex.build all green, tarball 0.3.0 ships artifacts dir).
ALL PHASE 3 TASKS COMPLETE — PR 3 open, pause for merge; then canary + tag with user coordination.
P1 Task 1: complete (commit cd4dd457 + facade fix 64cbb5b3; review Approved with Important [facade teardown store leak] → fixed, controller-verified; behavior freeze held, include-beats-exclude ExUnit lesson recorded). Suite 241, strict credo clean.
P1 Task 2: complete (commit 0130ba4d, preflight PASS, review Approved after reviewer-reconnect; delete_value normalize-both-sides verified — the trap; Elixir.File disambiguation clean). Suite 246, strict credo clean. Minors recorded (brief-inherited, accepted): repeat corrupt-warning on stateless reads; tmp leak on write! raise; no fsync (documented workstation posture); Contract cross-file coupling (test/support refactor candidate); atomicity test single-reader.
P1 QA-CHECKPOINT A: complete (QA doc, 17/17, 0 code bugs; real cross-OS-process reuse PROVEN via two mix run invocations; doc_issue [evict JSON-encodable note] → controller fix pre-PR; test_gap [cross-process invariant manual-only] ACCEPTED). Stack rebased onto main post-#45/#46 (outputs convention + @outputs_dir constant); ledger conflict resolved by controller.
P1 PR 1 (#47): MERGED (main 9c9d95b7). Suite 248 + strict credo green on new base.
USER DIRECTIVE: stack P3 on P2 (user away) — PR 2 opens without merge-pause; PR 3 bases on PR 2 branch; v0.4.0 tag waits for user.
── Phase 2 ──
- [x] P2 Task 3: ensure_environment
- [x] P2 Task 4: tags
- [x] P2 Task 5: prune
- [ ] P2 QA-B + PR 2 (no pause)
P2 Task 3: complete (commit 80a639be after two fix rounds: [1] controller caught wrong-direction deviation — 3-branch recovery taxonomy restored, brief test bug fixed test-side; [2] review Important atomize_handle totality → normalize_or_miss with rebuild-on-malformed + regression; rename Minor folded). Review Approved; digest-vs-storekey semantics verified. Suite 255, strict credo clean. Minor recorded: facade delegates around Provisioner (layering consistency) — final-review candidate.
P2 Task 4: complete (commit 9190715b after fix round: ArgumentError on malformed ref + test; untracked/4 deleted — implementer caught controller else-scoping bug, threaded digest via tagged tuple; corrupt-registry catch-all; single-writer comment). Review Approved-after-fixes. Suite 259, strict credo clean.
P2 Task 5: complete (commit 29cba367 after Critical fix round: cross-prefix base collision — strict 8-hex suffix membership in live_versions/2, replace_prefix throughout, 2 isolation regressions RED→GREEN; oldest-first archive order deviation judged correct). Re-review Approved; 8-hex filter verified consistent with minting. Suite 263, strict credo clean. Accepted-by-design note: foreign env named exactly <base>_<8hex> is indistinguishable (inherent to name-based membership).
P2 QA-CHECKPOINT B: complete (QA doc 864dc6d5, 21/22; code_bug [normalize_or_miss atom clause over-match] + keep-matrix/index-survival test_gaps + parts:2 doc_issue ALL FIXED in f1088a48 with regressions incl. malformed-entry heal). Suite 264, strict credo clean.
P2 COMPLETE — PR 2 opening WITHOUT pause per user stacking directive.
── Phase 3 (stacked on P2) ──
- [x] P3 Task 6: runtimes spec surface
- [x] P3 Task 7: SPIKE — mechanism proven
- [x] P3 Task 8: realization
- [x] P3 Task 9: canary legs
- [x] P3 Task 10: docs+CHANGELOG
- [ ] P3 QA-C
- [ ] P3 Task 11: v0.4.0 stamp + PR 3 (stacked on PR 2 branch)
P3 Task 6: complete (commit 2b667164 after fix round: version regex guard [shell-injection close, guard/body split], string-keyed networking merge, priv_dir actionable raise, SpyStore ordering test). Review Approved-with-fixes, all folded. Suite 297, strict credo clean.
P3 Task 7 SPIKE: COMPLETE — mechanism (b) PROVEN live in 4 rounds on probe/runtime-spike branch. Verdict: CMA sandbox = Ubuntu 24.04 x86_64 root+sudo, apt present, network open; mise installs in seconds; mise erlang PRECOMPILED for ubuntu-24.04 (erlang@29.0.2 in 5.4s, elixir 1.4s); full flow mise-installer→PATH export→use --global erlang→elixir → Elixir 1.20.2/OTP29 running (~11s total). Learnings for Task 8: template must prepend mise installer + PATH export (~/.local/bin + shims); persist PATH+locale to ~/.bashrc for subsequent agent bash calls; locale warning validates C.UTF-8 exports; ordering (erlang before elixir) is LOAD-BEARING (round-3 failure without it); apt fallback rejected (OTP 25 too old). Realization shape: handle carries bootstrap (mechanism c enriched) — no server-side build phase exists on CMA cloud envs. Surveys: scratchpad sdd040/spike-survey{2,3,4}.txt.
P3 Task 8: complete (commit 8336cb6d, one watchdog-stall resume; review Approved clean — shell script verified safe under pipefail incl. grep-guard/heredoc-quoting/curl-pipe analysis; derive-not-store enforced structurally + PutSpyStore). Suite 308, strict credo clean. Minor recorded: system_prompt_block prose lists runtimes in input order vs script install order (cosmetic) — final-review candidate.
P3 Task 9: complete (commit 08ab443d; controller-verified diff: 3 legs pinned to rma_canary image, :live_env_images full-lifecycle self-cleaning leg, :live_runtime productized-spike leg on sonnet; live legs validate post-merge in canary; repeat runs exercise 409-recovery live). Offline 308, strict credo clean.
P3 Task 10: complete (commit e025c147; controller check: image table + worked example + runtimes subsection in README voice; controller fixed tilde-expansion footgun in Store.File example [Path.expand]; CHANGELOG v0.4.0 unreleased section). Gates green incl. docs build.
