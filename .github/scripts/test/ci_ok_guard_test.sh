#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"; JQ="$HERE/ci-ok-guard.jq"; SCRIPT="$HERE/ci-ok-guard.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want '$2', got '$3')"; fail=1; fi; }
v() { jq -r -f "$JQ" <<<"{\"check_runs\":[$1]}"; }
run() { printf '{"name":"ci-ok","status":"%s","conclusion":%s,"completed_at":%s}' "$1" "$2" "$3"; }

check "no run is missing" missing "$(v '')"
check "one success passes" pass "$(v "$(run completed '"success"' '"2026-10-02T10:00:00Z"')")"
check "one failure fails" "fail:failure" "$(v "$(run completed '"failure"' '"2026-10-02T10:00:00Z"')")"
for c in neutral skipped cancelled timed_out action_required stale; do
  check "conclusion $c fails" "fail:$c" "$(v "$(run completed "\"$c\"" '"2026-10-02T10:00:00Z"')")"
done
check "the latest completed decides (failure after success)" "fail:failure" \
  "$(v "$(run completed '"success"' '"2026-10-02T10:00:00Z"'),$(run completed '"failure"' '"2026-10-02T11:00:00Z"')")"
check "the latest completed decides (success after failure)" pass \
  "$(v "$(run completed '"failure"' '"2026-10-02T10:00:00Z"'),$(run completed '"success"' '"2026-10-02T11:00:00Z"')")"
check "a running re-run is waited on" pending \
  "$(v "$(run completed '"success"' '"2026-10-02T10:00:00Z"'),$(run in_progress null null)")"
check "another check's name is ignored" missing "$(v '{"name":"scan","status":"completed","conclusion":"success","completed_at":"2026-10-02T10:00:00Z"}')"

# The loop, against a fake gh.
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT; mkdir -p "$d/bin"
printf '#!/usr/bin/env bash\n[ -n "${FAKE_FAIL:-}" ] && { echo "gh: HTTP 502" >&2; exit 1; }\nprintf "%%s\\n" "$FAKE_BODY"\n' > "$d/bin/gh"; chmod +x "$d/bin/gh"
guard() { PATH="$d/bin:$PATH" CI_OK_WAIT_SECONDS=0 CI_OK_POLL_SECONDS=0 FAKE_BODY="$1" FAKE_FAIL="${2:-}" bash "$SCRIPT" o/r abc >/dev/null 2>&1; echo $?; }
check "guard: pass exits 0" 0 "$(guard "{\"check_runs\":[$(run completed '"success"' '"2026-10-02T10:00:00Z"')]}")"
check "guard: pending past the deadline exits 1" 1 "$(guard "{\"check_runs\":[$(run queued null null)]}")"
check "guard: missing exits 1" 1 "$(guard '{"check_runs":[]}')"
check "guard: an API error exits non-zero" 1 "$([ "$(guard '{}' yes)" -ne 0 ] && echo 1 || echo 0)"
exit $fail
