# Provider/Session Abstraction v2 — Progress Ledger

Base: origin/main @ 1f999ff. Bookmark: ryan/provider-session-abstraction. Docs: 1adbc583.
Baseline: `mix test` → 110 passed, 4 excluded. PR #12 (v1) closed/abandoned.
Reuse source (copy v1 modules from): .claude/worktrees/provider-abstraction

## Tasks
- [x] Task 1: Provider behaviour (invocation surface) — commit 5fccb335, 3 tests, suite 113
- [x] Task 2: Providers.BedrockAgentCore (request_response) — 12 tests, suite 125 (agent stalled; controller finished + fixed eager Client.new)
- [ ] Task 3: Providers.ClaudeManagedAgents (streaming)
- [ ] Task 4: Unified Session core loop + fake-provider tests
- [ ] Task 5: Session live UX (start_link/message/notify/handle_event/reconnect)
- [ ] Task 6: Collapse old drivers into Session
- [ ] Task 7: Cross-mode conformance + cleanup

## Log
(append one line per task as reviews come back clean)
