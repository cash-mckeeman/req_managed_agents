#!/usr/bin/env bash
# Structural: the lines of publish.yml that decide whether a run can publish.
# No script suite runs the workflow, so these are the only repository gate on them.
set -u
WF="$(cd "$(dirname "$0")/../.." && pwd)/workflows/publish.yml"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want '$2', got '$3')"; fail=1; fi; }
lines() { grep -cxF -- "$1" "$WF"; }
# step <name> <key>: the value lines of <key> inside the step named <name>.
step() { awk -v n="      - name: $1" -v k="$2:" '$0 == n {f=1; next} f && /^      - / {exit} f && index($1, k) == 1 {print}' "$WF"; }

check "a manual run is always a dry run" 1 "$(lines "      DRY_RUN: \${{ github.event_name == 'push' && '0' || '1' }}")"
check "nothing else sets DRY_RUN" 1 "$(grep -c 'DRY_RUN:' "$WF")"
check "each guard may continue past a failure only in a dry run" 4 "$(lines "        continue-on-error: \${{ env.DRY_RUN == '1' }}")"
check "no other step continues past a failure" 4 "$(grep -c 'continue-on-error:' "$WF")"
# No status function: on a tag push a failed guard skips both publish steps.
for pkg in req_managed_agents req_managed_agents_host; do
  check "publish $pkg runs only when every guard passed" \
    "        if: contains(format(' {0} ', steps.plan.outputs.packages), ' $pkg ')" "$(step "publish $pkg" if)"
done
check "the version check can fail" 1 "$(lines "          exit \$bad")"
check "no step carries a Hex key" 0 "$(grep -c 'HEX_API_KEY' "$WF")"
check "no line reads a secret" 0 "$(grep -v '^ *#' "$WF" | grep -c 'secrets')"
check "the job may mint an OIDC token" 1 "$(lines "      id-token: write")"
check "only the publish job holds id-token" 1 "$(grep -c 'id-token:' "$WF")"
check "the job keeps contents: read" 1 "$(lines "      contents: read")"
check "the job keeps checks: read" 1 "$(lines "      checks: read")"
check "the job runs in prod, where hex.pm trusts it" 1 "$(lines "    environment: prod")"
check "the Hex version guard runs the script" "        run: bash .github/scripts/hex-workload-identity.sh" "$(step 'hex supports workload identity' run)"
check "the Hex version guard precedes the plan and both publishes" 1 \
  "$([ "$(grep -n 'name: hex supports workload identity' "$WF" | cut -d: -f1)" -lt "$(grep -n 'id: plan' "$WF" | cut -d: -f1)" ] && echo 1 || echo 0)"
check "a dry run always ends in the verdict step" "        if: always() && env.DRY_RUN == '1'" "$(step 'dry-run verdict' if)"
check "the verdict fails on any guard failure" 1 "$(lines "          case \"\$OUTCOMES\" in *failure*) exit 1 ;; esac")"
check "reachability walks main's first-parent history" 1 "$(lines "        run: git rev-list --first-parent origin/main | grep -x \"\$GITHUB_SHA\" > /dev/null")"
exit $fail
