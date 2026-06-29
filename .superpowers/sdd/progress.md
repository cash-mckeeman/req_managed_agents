# Provider Streaming Abstraction — Progress Ledger

Base: origin/main @ 1f999ff (MIM-43 merged; MIM-52 parse fix present)
Bookmark: ryan/provider-streaming-abstraction
Docs commit: fc6bde27 (spec + plan)

Baseline: `mix test` → 110 passed, 4 excluded (green).

## Tasks
- [x] Task 1: Provider behaviour + canonical types + result_of/2
- [x] Task 2: Providers.AgentCore
- [x] Task 3: Providers.ManagedAgents
- [x] Task 4: Refactor invoke_to_completion through Providers.AgentCore
- [ ] Task 5: Refactor RunToCompletion through Providers.ManagedAgents + terminal collapse
- [ ] Task 6: Cross-provider conformance/symmetry/exclusion tests
- [ ] Task 7: Terminal-collapse call-site audit + retire Event.classify

## Log
- Task 1: complete (commit 56bd8c0d, 3 tests, self-review clean, suite 113 passed)
- Task 2: complete (commit 0899650e, 7 tests incl MIM-52 + exclusion, review clean, suite 120 passed)
- Task 3: complete (commit e96f12a9, 8 tests incl most-recent-idle + exclusion, review clean, suite 128 passed)
- Task 4: complete (commit e2a4ad27, agent_core 30/30, warnings-as-errors clean, suite 128 passed)
