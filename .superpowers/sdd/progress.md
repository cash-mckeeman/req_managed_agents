# Provider/Session Abstraction v2 — Progress Ledger

Base: origin/main @ 1f999ff. Bookmark: ryan/provider-session-abstraction. Docs: 1adbc583.
Baseline: `mix test` → 110 passed, 4 excluded. PR #12 (v1) closed/abandoned.
Reuse source (copy v1 modules from): .claude/worktrees/provider-abstraction

## Tasks
- [x] Task 1: Provider behaviour (invocation surface) — commit 5fccb335, 3 tests, suite 113
- [x] Task 2: Providers.BedrockAgentCore (request_response) — 12 tests, suite 125 (agent stalled; controller finished + fixed eager Client.new)
- [x] Task 3: Providers.ClaudeManagedAgents (streaming) — commit fe29301a, 21 tests, suite 146
- [x] Task 4: Unified Session core loop + fake-provider tests — commit 64c346fd, loop 4/4 (both modes proven), suite 150
- [x] Task 5a: Session live UX (start_link/message/child_spec) — commit e0177c65, 2 tests, suite 152
- [ ] Task 5b: Session reconnect-with-consolidation (provider reconnect/3 callback + seen-dedup)
- [ ] Task 6: Collapse old drivers into Session
- [ ] Task 7: Cross-mode conformance + cleanup

## Log
(append one line per task as reviews come back clean)
