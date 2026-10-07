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
check "the RMA step gets the RMA key, on a tag push only" \
  "          HEX_API_KEY: \${{ github.event_name == 'push' && secrets.HEX_API_KEY || '' }}" "$(step 'publish req_managed_agents' HEX_API_KEY)"
check "the RMAH step gets the RMAH key, on a tag push only" \
  "          HEX_API_KEY: \${{ github.event_name == 'push' && secrets.HEX_API_KEY_RMAH || '' }}" "$(step 'publish req_managed_agents_host' HEX_API_KEY)"
check "the key check runs on a tag push only" \
  "        if: github.event_name == 'push'" "$(step "every selected package's Hex key is set" if)"
check "the key check reads the RMA key" \
  "          KEY_RMA: \${{ secrets.HEX_API_KEY }}" "$(step "every selected package's Hex key is set" KEY_RMA)"
check "the key check reads the RMAH key" \
  "          KEY_RMAH: \${{ secrets.HEX_API_KEY_RMAH }}" "$(step "every selected package's Hex key is set" KEY_RMAH)"
check "the version check and the key check can each fail" 2 "$(lines "          exit \$bad")"
check "the key check precedes the first publish" 1 "$([ "$(grep -n "name: every selected package's Hex key is set" "$WF" | cut -d: -f1)" -lt "$(grep -n 'name: publish req_managed_agents$' "$WF" | cut -d: -f1)" ] && echo 1 || echo 0)"
check "the key check checks the planned packages" \
  "          PACKAGES: \${{ steps.plan.outputs.packages }}" "$(step "every selected package's Hex key is set" PACKAGES)"
check "the key check tests the RMA key for req_managed_agents" 1 \
  "$(lines "              req_managed_agents) [ -n \"\$KEY_RMA\" ] || { echo \"::error::HEX_API_KEY is empty; \$p cannot be published\"; bad=1; } ;;")"
check "the key check tests the RMAH key for req_managed_agents_host" 1 \
  "$(lines "              req_managed_agents_host) [ -n \"\$KEY_RMAH\" ] || { echo \"::error::HEX_API_KEY_RMAH is empty; \$p cannot be published\"; bad=1; } ;;")"
check "the key check has one arm per package and one fallback" 3 "$(grep -cE '^              [^ ]+\) ' "$WF")"
check "no other line reads a secret" 4 "$(grep -v '^ *#' "$WF" | grep -c 'secrets')"
check "a dry run always ends in the verdict step" "        if: always() && env.DRY_RUN == '1'" "$(step 'dry-run verdict' if)"
check "the verdict fails on any guard failure" 1 "$(lines "          case \"\$OUTCOMES\" in *failure*) exit 1 ;; esac")"
check "reachability walks main's first-parent history" 1 "$(lines "        run: git rev-list --first-parent origin/main | grep -x \"\$GITHUB_SHA\" > /dev/null")"
exit $fail
