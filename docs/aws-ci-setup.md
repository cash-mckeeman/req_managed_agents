# AWS setup for the live canary (CI)

Reference for the CI-scoped AWS resources behind `.github/workflows/live-canary.yml`
(MIM-44). Created 2026-07-02 in account `819613816573`, region `us-east-1`.
GitHub Actions authenticates via OIDC federation — **no long-lived AWS keys
exist in GitHub**.

## Resource inventory

| Resource | Name / ARN | Purpose |
|---|---|---|
| OIDC provider | `arn:aws:iam::819613816573:oidc-provider/token.actions.githubusercontent.com` | Lets GitHub Actions mint short-lived AWS credentials (account-wide; shared by any future CI role) |
| IAM role | `arn:aws:iam::819613816573:role/rma-ci-github` | Assumed by the canary workflow. Trust is scoped to `repo:cash-mckeeman/req_managed_agents:ref:refs/heads/main` — no other repo, branch, or fork can assume it |
| IAM role | `arn:aws:iam::819613816573:role/rma-ci-harness-exec` | Passed to AgentCore as the harness execution role for CI-provisioned harnesses |

`rma-ci-github` permissions: the five harness lifecycle actions
(`CreateHarness` / `GetHarness` / `ListHarnesses` / `DeleteHarness` /
`InvokeHarness`) on `arn:aws:bedrock-agentcore:us-east-1:819613816573:*`, plus
`iam:PassRole` of `rma-ci-harness-exec` restricted to
`bedrock-agentcore.amazonaws.com`.

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

- The harness-lifecycle statement is region+account scoped, not name-scoped:
  AgentCore harness ARN naming wasn't confirmed at setup time. Once a CI run
  has produced real harness ARNs (visible in CloudTrail), tighten `Resource`
  to the observed `rma_live*` pattern.
- `ListHarnesses` generally requires a broad resource anyway (it's a list
  call); keep it split into its own statement if the rest gets name-scoped.

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
