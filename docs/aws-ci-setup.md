# AWS setup for the live canary (CI)

Reference for the CI-scoped AWS resources behind `.github/workflows/live-canary.yml`
(MIM-44). Created 2026-07-02 in account `819613816573`, region `us-east-1`.
GitHub Actions authenticates via OIDC federation — **no long-lived AWS keys
exist in GitHub**.

## Resource inventory

| Resource | Name / ARN | Purpose |
|---|---|---|
| OIDC provider | `arn:aws:iam::819613816573:oidc-provider/token.actions.githubusercontent.com` | Lets GitHub Actions mint short-lived AWS credentials (account-wide; shared by any future CI role) |
| IAM role | `arn:aws:iam::819613816573:role/rma-ci-github` | Assumed by the canary workflow. Trust accepts two `sub` claims: `repo:cash-mckeeman/req_managed_agents:environment:prod` (what jobs declaring `environment: prod` present) and `repo:...:ref:refs/heads/main` — no other repo, branch, or fork can assume it |
| IAM role | `arn:aws:iam::819613816573:role/rma-ci-harness-exec` | Passed to AgentCore as the harness execution role for CI-provisioned harnesses |

`rma-ci-github` permissions (policy `rma-ci-harness-lifecycle`, validated
live by canary run 9 on 2026-07-03 — see the permission ladder below):

- Create/Get/Delete/Invoke in **both namings** (`*AgentRuntime*` and
  `*Harness*` action names) + endpoint lifecycle, on `runtime/*`,
  `runtime/*/runtime-endpoint/*`, `harness/*`, `harness/*/harness-endpoint/*`
- `ListAgentRuntimes` / `ListHarnesses` on the account+region
- `CreateWorkloadIdentity` / `GetWorkloadIdentity` / `DeleteWorkloadIdentity`
  on `workload-identity-directory/default(/workload-identity/*)`
- `CreateMemory` / `GetMemory` / `DeleteMemory` / `ListMemories` on
  `memory/harness_rma_live*` (name-scoped)
- `iam:PassRole` of `rma-ci-harness-exec` restricted to
  `bedrock-agentcore.amazonaws.com`

### The permission ladder (empirical, GA Harness API, 2026-07-03)

A single `CreateHarness` call authorizes **five things against the caller**,
discovered one 403 at a time (none of this was in AWS docs at the time):

1. `bedrock-agentcore:CreateAgentRuntime` on `runtime/*` — the legacy action
   name is checked first
2. `bedrock-agentcore:CreateHarness` on `harness/*` — then the GA name
   (dual authorization during the rename transition)
3. `bedrock-agentcore:CreateAgentRuntimeEndpoint` — the implicit DEFAULT
   endpoint, created async with the **caller's** identity (surfaces as
   `CREATE_FAILED` + `failureReason`, not a synchronous 403)
4. `bedrock-agentcore:CreateWorkloadIdentity` on
   `workload-identity-directory/default/workload-identity/*` — same async
   caller-identity pattern
5. `bedrock-agentcore:CreateMemory` on `memory/harness_<name>_*` — the
   harness's built-in memory, ditto (error cites
   `Service: GenesisMemoryControlPlane`)

Also learned:

- **OIDC `sub` claim changes with environments**: a job that declares
  `environment: prod` presents `repo:<org>/<repo>:environment:prod`, not
  `ref:refs/heads/main`. Trust policies pinned to the branch fail with
  "Not authorized to perform sts:AssumeRoleWithWebIdentity".
- **Deterministic harness names collide with slow deletes**: the provisioner
  derives the harness name from a spec hash, and `DeleteHarness` takes
  minutes (memory teardown). A retry while the old harness is `DELETING`
  fails with `:harness_name_conflict`. Wait for the delete to finish (or
  teach `Provisioner.ensure` to wait on `DELETING`).

`rma-ci-harness-exec` permissions: a copy of the live-proven
`AgentCoreHarnessExecRole-p2b` policy with model invocation narrowed to
**Nemotron only** (`foundation-model/nvidia.nemotron*` +
`inference-profile/us.nvidia.*`) — the CI Bedrock lane runs Nemotron by
design (cheap); the CMA lanes bill Anthropic directly and use Haiku.

## GitHub configuration

- `prod` **environment secrets** (both workflows declare `environment: prod`):
  `ANTHROPIC_API_KEY` (CMA lanes), `HEX_API_KEY` (publish workflow).
- Repository **variables** (not secret; role ARNs are not sensitive):
  - `AWS_ROLE_ARN` = `arn:aws:iam::819613816573:role/rma-ci-github`
  - `HARNESS_EXECUTION_ROLE_ARN` = `arn:aws:iam::819613816573:role/rma-ci-harness-exec`

## Model defaults (override per run)

| Lane | Default | Override env |
|---|---|---|
| CMA (Anthropic) | `claude-haiku-4-5` | `CMA_LIVE_MODEL` |
| Bedrock AgentCore | `nvidia.nemotron-super-3-120b` | `BEDROCK_LIVE_MODEL_ID` |

Temporary OIDC credentials carry a session token; `AgentCore.SigV4.from_env/0`
reads `AWS_SESSION_TOKEN` and the signer emits `x-amz-security-token`, so no
special handling is needed.

## Known coarseness / follow-ups

- Runtime/harness resources are type-scoped (`runtime/*`, `harness/*`), not
  name-scoped; memory IS name-scoped (`memory/harness_rma_live*`). Harness
  ARNs embed the name, so `harness/rma_live*` should work if further
  tightening is wanted.
- `Provisioner.ensure` treats a `DELETING` harness with the same name as a
  conflict rather than waiting — worth a Linear issue if the canary flakes
  on back-to-back runs.

## Teardown

The canary deletes its harnesses (provision → invoke → teardown), so steady
state leaves nothing behind. To remove the CI infrastructure entirely:

```bash
aws iam delete-role-policy --role-name rma-ci-github --policy-name rma-ci-harness-lifecycle
aws iam delete-role --role-name rma-ci-github
aws iam delete-role-policy --role-name rma-ci-harness-exec --policy-name rma-ci-harness-perms
aws iam delete-role --role-name rma-ci-harness-exec
# Only if nothing else federates GitHub -> this account:
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::819613816573:oidc-provider/token.actions.githubusercontent.com
```

Orphaned CI harnesses (a canary run that died mid-test) are visible via
`ListHarnesses` with the `rma_live` name prefix and safe to delete.
