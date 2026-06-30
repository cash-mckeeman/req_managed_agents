# QA-CHECKPOINT

Canonical proof that the Provider/Session refactor (the unified `Session` replacing the three old
drivers) changed **no observable behavior** of either provider.

```
mix req_managed_agents.qa_checkpoint
```

## What it does

1. Creates a throwaway jj worktree at the baseline revision (`--base`, default `main@origin` =
   the PR #11 state, with the three old drivers).
2. Runs the same capture (`qa/checkpoint_capture_test.exs`) against **both** the baseline (PR11)
   and the current worktree (PR13).
3. Diffs the two behavior fingerprints scenario-by-scenario and prints a verdict. Exits non-zero
   if any compared field diverges.

The capture drives **both providers** through the public facade
(`ReqManagedAgents.run_to_completion/1`, `ReqManagedAgents.AgentCore.invoke_to_completion/1` —
identical at PR11 and PR13) with **deterministic transports**, so the only variable is the
codebase:

- **Bedrock AgentCore** (`request_response`) — scripted via the `invoke_fun` seam (no AWS).
- **Claude Managed Agents** (`streaming`) — scripted via a Bypass SSE stub (no network).

## Fingerprint fields

Per scenario the capture records, and the task compares for pass/fail:

`result` · `terminal` · `stop_reason_type` (normalized) · `tool_calls` · `n_final_events` · `error`

One field — `stop_reason_raw_kind` — is **informational/allow-listed**: it surfaces the one
documented intentional change (Claude `stop_reason` map→string; see the spec's "Intentional
behavior changes"). It is reported, never failed.

## Scenarios

`bedrock/{end_turn, single_tool, multi_tool, stream_error}` and
`claude/{end_turn, single_tool, handler_error}` — covering the no-tool path, return-of-control
tool loops (single + parallel), provider stream errors, and tool-handler errors.

## Options

- `--base REV` — baseline revision (default `main@origin`)
- `--rebuild` — recreate the baseline worktree from scratch (otherwise it's reused for speed)

The pass/fail comparison itself is unit-tested in
`test/req_managed_agents/qa_checkpoint_test.exs` — a gate that cannot fail proves nothing.

## Cleanup

The baseline worktree is left in place for fast re-runs. To remove it:

```
jj workspace forget qa-checkpoint-pr11
rm -rf .claude/worktrees/qa-checkpoint-pr11
```
