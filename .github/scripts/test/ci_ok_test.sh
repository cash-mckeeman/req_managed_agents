#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"; SCRIPT="$HERE/ci-ok.sh"; CI="$HERE/../workflows/ci.yml"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want $2, got $3)"; fail=1; fi; }
verdict() { NEEDS="$1" bash "$SCRIPT" >/dev/null 2>&1; echo $?; }
# needs <detect-changes result> <its outputs JSON> <root> <test> <quality> <dialyzer>
needs() {
  printf '{"detect-changes":{"result":"%s","outputs":%s},"root":{"result":"%s","outputs":{}},"test":{"result":"%s","outputs":{}},"quality":{"result":"%s","outputs":{}},"dialyzer":{"result":"%s","outputs":{}}}' "$@"
}
BOTH='{"packages":"[\"req_managed_agents\",\"req_managed_agents_host\"]","root":"true"}'
NONE='{"packages":"[]","root":"false"}'

check "all selected, all green" 0 "$(verdict "$(needs success "$BOTH" success success success success)")"
check "detect-changes failed" 1 "$(verdict "$(needs failure '{}' skipped skipped skipped skipped)")"
check "detect-changes cancelled" 1 "$(verdict "$(needs cancelled '{}' skipped skipped skipped skipped)")"
check "detect-changes produced no outputs" 1 "$(verdict "$(needs success '{}' skipped skipped skipped skipped)")"
check "a selected test failed" 1 "$(verdict "$(needs success "$BOTH" success failure success success)")"
check "a selected job was skipped" 1 "$(verdict "$(needs success "$BOTH" success skipped success success)")"
check "a selected job was cancelled" 1 "$(verdict "$(needs success "$BOTH" success success cancelled success)")"
check "docs-only: nothing selected, all skipped" 0 "$(verdict "$(needs success "$NONE" skipped skipped skipped skipped)")"
check "not selected, yet it failed" 1 "$(verdict "$(needs success "$NONE" skipped failure skipped skipped)")"
check "root missing cannot bypass the gate" 1 "$(verdict "$(needs success "$BOTH" success success success success | jq 'del(.root)')")"
check "empty needs" 1 "$(verdict '{}')"
check "no needs at all" 1 "$(verdict '')"
check "no root flag" 1 "$(verdict "$(needs success '{"packages":"[]","root":""}' skipped skipped skipped skipped)")"
check "detect-changes cancelled, outputs present" 1 "$(verdict "$(needs cancelled "$BOTH" success success success success)")"

# Structural: ci-ok needs every other job in ci.yml. A job missing from needs
# is a job ci-ok cannot see.
jobs=$(awk '/^jobs:/{f=1; next} f && /^  [A-Za-z0-9_-]+:/ {sub(/^  /, ""); sub(/:.*/, ""); print}' "$CI" | grep -vx ci-ok | sort)
needs_line=$(awk '/^  ci-ok:/{f=1} f && /^    needs:/ {print; exit}' "$CI" | sed 's/.*\[//; s/\].*//' | tr ',' '\n' | tr -d ' ' | sort)
check "ci.yml has jobs to compare" yes "$([ "$(printf '%s\n' "$jobs" | grep -c .)" -ge 5 ] && echo yes || echo no)"
check "ci-ok needs every other job" "$jobs" "$needs_line"
# Without `if: always()` ci-ok is skipped when a needed job fails, and GitHub
# reads a skipped required check as passing.
ci_ok_if=$(awk '/^  ci-ok:/{f=1; next} f && /^  [A-Za-z0-9_-]+:/{exit} f && /^    if:/ {print; exit}' "$CI")
check "ci-ok runs on every outcome" "    if: always()" "$ci_ok_if"
exit $fail
