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
check "the latest decides in any array order (newer failure listed first)" "fail:failure" \
  "$(v "$(run completed '"failure"' '"2026-10-02T11:00:00Z"'),$(run completed '"success"' '"2026-10-02T10:00:00Z"')")"
check "the latest decides in any array order (newer success listed first)" pass \
  "$(v "$(run completed '"success"' '"2026-10-02T11:00:00Z"'),$(run completed '"failure"' '"2026-10-02T10:00:00Z"')")"
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

# Waiting and failing are different exits. A scripted gh answers call N with
# $Q/N (the last answer repeats) and counts its calls.
q="$(mktemp -d)"; trap 'rm -rf "$d" "$q"' EXIT; mkdir -p "$q/bin"
cat > "$q/bin/gh" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$Q/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$Q/calls"
f="$Q/$n"; [ -f "$f" ] || f="$Q/last"
cat "$f"
STUB
chmod +x "$q/bin/gh"
# scripted <wait s> <answer>...: prints "exit calls"
scripted() {
  local wait="$1" i=0 a; shift; rm -f "$q"/[0-9]* "$q/last" "$q/calls"
  for a in "$@"; do i=$((i + 1)); printf '%s\n' "$a" > "$q/$i"; cp "$q/$i" "$q/last"; done
  PATH="$q/bin:$PATH" Q="$q" CI_OK_WAIT_SECONDS="$wait" CI_OK_POLL_SECONDS=1 bash "$SCRIPT" o/r abc >"$q/out" 2>&1
  echo "$? $(cat "$q/calls" 2>/dev/null || echo 0)"
}
ok="{\"check_runs\":[$(run completed '"success"' '"2026-10-02T10:00:00Z"')]}"
bad="{\"check_runs\":[$(run completed '"failure"' '"2026-10-02T10:00:00Z"')]}"
check "guard: a run that appears on the second look is waited for and passes" "0 2" "$(scripted 2 '{"check_runs":[]}' "$ok")"
check "guard: a pending run that completes is waited for and passes" "0 2" "$(scripted 2 "{\"check_runs\":[$(run queued null null)]}" "$ok")"
check "guard: a failed latest run fails at the first look, without waiting" "1 1" "$(scripted 2 "$bad" "$ok")"
check "guard: a missing run is logged as missing" "ci-ok: missing on abc; next look in 1s" "$(scripted 2 '{"check_runs":[]}' "$ok" >/dev/null; head -1 "$q/out")"
check "guard: a pending run is logged as pending" "ci-ok: pending on abc; next look in 1s" "$(scripted 2 "{\"check_runs\":[$(run queued null null)]}" "$ok" >/dev/null; head -1 "$q/out")"
check "guard: a run that never appears ends with the missing line" "ci-ok: missing on abc after 0s" "$(scripted 0 '{"check_runs":[]}' >/dev/null; tail -1 "$q/out")"
check "guard: a wait of '08' is read as decimal, not rejected as octal" "0 2" "$(scripted 08 '{"check_runs":[]}' "$ok")"
for w in abc -1 1.5 "1 2"; do
  check "guard: a wait of '$w' is rejected before any look" "2 0" "$(scripted "$w" '{"check_runs":[]}')"
done
exit $fail
