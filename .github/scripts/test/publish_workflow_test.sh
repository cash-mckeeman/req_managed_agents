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

# job <name>: the lines of that job, up to the next top-level job.
job() { awk -v n="  $1:" '$0 == n {f=1; next} f && /^  [a-z_-]+:/ {exit} f' "$WF"; }
# jstep <job> <name> <key>: <step>'s value lines of <key>, within one job.
jstep() { job "$1" | awk -v n="      - name: $2" -v k="$3:" '$0 == n {f=1; next} f && /^      - / {exit} f && index($1, k) == 1 {print}'; }
# before <job> <a> <b>: 1 when the first line of <job> matching <a> comes before the first matching <b>.
before() { local x y; x="$(job "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1)"; y="$(job "$1" | grep -nF -- "$3" | head -1 | cut -d: -f1)"
  [ -n "$x" ] && [ -n "$y" ] && [ "$x" -lt "$y" ] && echo 1 || echo 0; }

check "both jobs exist" 2 "$(for j in guard publish; do [ -n "$(job $j)" ] && echo x; done | wc -l | tr -d ' ')"
check "a manual run is always a dry run" 1 "$(lines "      DRY_RUN: \${{ github.event_name == 'push' && '0' || '1' }}")"
check "the publish job is never a dry run" 1 "$(job publish | grep -c '      DRY_RUN: "0"')"
check "no other line sets DRY_RUN" 2 "$(grep -c 'DRY_RUN:' "$WF")"
check "each guard may continue past a failure only in a dry run" 5 "$(job guard | grep -cxF "        continue-on-error: \${{ env.DRY_RUN == '1' }}")"
check "no other step continues past a failure" 5 "$(grep -c 'continue-on-error:' "$WF")"
check "the publish job continues past nothing" 0 "$(job publish | grep -c 'continue-on-error')"
# The Hex guard is a rehearsal guard too: its outcome is in the dry-run verdict.
check "a rehearsal lists the Hex guard in its outcomes" 2 "$(grep -c 'OUTCOMES: hex=\${{ steps.hex.outcome }} plan=' "$WF")"
check "the Hex guard step in the guard job is id hex" 1 "$(job guard | grep -c '        id: hex')"
# No status function: a failed guard skips the rehearsal steps, and `needs` skips publish.
for pkg in aws_event_stream req_managed_agents req_managed_agents_host; do
  check "rehearse $pkg runs on a manual run only, after every guard passed" \
    "        if: github.event_name != 'push' && contains(format(' {0} ', steps.plan.outputs.packages), ' $pkg ')" "$(jstep guard "rehearse $pkg" if)"
  check "publish $pkg runs only for a planned package" \
    "        if: contains(format(' {0} ', needs.guard.outputs.packages), ' $pkg ')" "$(jstep publish "publish $pkg" if)"
done
check "the version check can fail" 1 "$(job guard | grep -cxF "          exit \$bad")"
check "no step carries a Hex key" 0 "$(grep -c 'HEX_API_KEY' "$WF")"
check "no line reads a secret" 0 "$(grep -v '^ *#' "$WF" | grep -c 'secrets')"
check "id-token: write appears once in the file" 1 "$(grep -c 'id-token:' "$WF")"
check "the publish job holds it" 1 "$(job publish | grep -cxF "      id-token: write")"
check "the guard job holds no id-token" 0 "$(job guard | grep -c 'id-token')"
check "the publish job waits for the guard job" 1 "$(job publish | grep -cxF "    needs: guard")"
check "the publish job runs on a tag push only" 1 "$(job publish | grep -cxF "    if: github.event_name == 'push'")"
check "the guard job has no if of its own" 0 "$(job guard | grep -c '^    if:')"
check "the publish job keeps contents: read" 1 "$(job publish | grep -cxF "      contents: read")"
check "the guard job runs in no environment" 0 "$(job guard | grep -c 'environment:')"
check "the publish job runs in prod, where hex.pm trusts it" 1 "$(job publish | grep -cxF "    environment: prod")"
check "the publish job polls no checks" 0 "$(job publish | grep -c 'checks:')"
for j in guard publish; do
  check "$j runs the Hex version guard script" "        run: bash .github/scripts/hex-workload-identity.sh" "$(jstep $j 'hex supports workload identity' run)"
done
check "the Hex guard precedes the plan in the guard job" 1 "$(before guard 'hex supports workload identity' 'id: plan')"
check "the Hex guard precedes both publishes in the publish job" 1 "$(before publish 'hex supports workload identity' 'name: publish req_managed_agents')"
check "a dry run always ends in the verdict step" "        if: always() && env.DRY_RUN == '1'" "$(jstep guard 'dry-run verdict' if)"
check "the verdict fails on any guard failure" 1 "$(lines "          case \"\$OUTCOMES\" in *failure*) exit 1 ;; esac")"
check "reachability walks main's first-parent history" 1 "$(lines "        run: git rev-list --first-parent origin/main | grep -x \"\$GITHUB_SHA\" > /dev/null")"

# The publish job's first step refuses an empty plan; run its script as the runner would.
check "the publish job's first step is the plan check" "      - name: the guard job produced a publish plan" "$(job publish | awk '/^    steps:/ {f=1; next} f && /^      - / {print; exit}')"
plan_run="$(job publish | awk '/name: the guard job produced a publish plan/ {f=1; next} f && /^        run: \|/ {g=1; next} g && /^      - / {exit} g {sub(/^          /, ""); print}')"
plan() { ( PACKAGES="$1" KIND="$2" VERSION="$3" bash -c "$plan_run" >/dev/null 2>&1 ); echo $?; }
check "a full plan passes" 0 "$(plan 'req_managed_agents req_managed_agents_host' lockstep 0.17.0)"
check "an empty packages output fails" 1 "$(plan '' lockstep 0.17.0)"
check "an empty kind output fails" 1 "$(plan 'req_managed_agents' '' 0.17.0)"
check "an empty version output fails" 1 "$(plan 'req_managed_agents' patch '')"
check "the plan check names each missing output" 3 "$(printf '%s\n' "$plan_run" | grep -c '::error::the guard job published no')"
version_run="$(job guard | awk '/name: each selected package/ {f=1; next} f && /^        run: \|/ {g=1; next} g && /^      - / {exit} g {sub(/^          /, ""); print}')"
version_check() { (PACKAGES=aws_event_stream VERSION="$1" bash -c "$version_run" >/dev/null 2>&1); echo $?; }
check "matching codec metadata permits the selected release" 0 "$(version_check 0.2.1)"
check "mismatched codec metadata prevents the selected release" 1 "$(version_check 0.2.0)"
exit $fail
