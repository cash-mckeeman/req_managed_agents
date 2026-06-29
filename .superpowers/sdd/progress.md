# Provider Streaming Abstraction — Progress Ledger

Base: origin/main @ 1f999ff (MIM-43 merged; MIM-52 parse fix present)
Bookmark: ryan/provider-streaming-abstraction
Docs commit: fc6bde27 (spec + plan)

Baseline: `mix test` → 110 passed, 4 excluded (green).

## Tasks
- [ ] Task 1: Provider behaviour + canonical types + result_of/2
- [ ] Task 2: Providers.AgentCore
- [ ] Task 3: Providers.ManagedAgents
- [ ] Task 4: Refactor invoke_to_completion through Providers.AgentCore
- [ ] Task 5: Refactor RunToCompletion through Providers.ManagedAgents + terminal collapse
- [ ] Task 6: Cross-provider conformance/symmetry/exclusion tests
- [ ] Task 7: Terminal-collapse call-site audit + retire Event.classify

## Log
(append one line per task as reviews come back clean)
