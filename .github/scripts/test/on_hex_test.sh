#!/usr/bin/env bash
set -u
# Sourcing must never reach hex.pm: any curl the script runs lands in this stub.
stub="$(mktemp -d)"; trap 'rm -rf "$stub"' EXIT
printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls"; exit 1\n' "$stub" > "$stub/curl"; chmod +x "$stub/curl"
PATH="$stub:$PATH"
. "$(cd "$(dirname "$0")/.." && pwd)/on-hex.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want '$2', got '$3')"; fail=1; fi; }
check "200 is on Hex" yes "$(hex_answer 200)"
check "404 is not on Hex" no "$(hex_answer 404)"
for c in 429 500 502 000; do hex_answer "$c" >/dev/null 2>&1; check "HTTP $c is an error, not 'no'" 1 "$([ $? -ne 0 ] && echo 1 || echo 0)"; done
check "sourcing runs no curl" none "$(cat "$stub/calls" 2>/dev/null || echo none)"

# Run as a script, against a curl stub that records its argv and answers $FAKE_HTTP, exiting $FAKE_RC.
run="$(mktemp -d)"; trap 'rm -rf "$stub" "$run"' EXIT
printf '#!/usr/bin/env bash\necho "$*" > "%s/argv"; printf "%%s" "${FAKE_HTTP:-}"; exit "${FAKE_RC:-0}"\n' "$run" > "$run/curl"; chmod +x "$run/curl"
on_hex() { PATH="$run:$PATH" FAKE_HTTP="$1" FAKE_RC="${2:-0}" bash "$(cd "$(dirname "$0")/.." && pwd)/on-hex.sh" req_managed_agents 0.12.0 2>/dev/null; }
check "script: 200 prints yes" yes "$(on_hex 200)"
check "script: 404 prints no" no "$(on_hex 404)"
out="$(on_hex 000 28)"
check "script: a curl timeout (exit 28) prints nothing" "" "$out"
check "script: a curl timeout (exit 28) is an error" 1 "$([ "$(on_hex 000 28 >/dev/null; echo $?)" -ne 0 ] && echo 1 || echo 0)"
on_hex 404 >/dev/null
check "script: curl is bounded, shows errors, and asks for this release" \
  "-sS --connect-timeout 10 --max-time 60 -o /dev/null -w %{http_code} https://hex.pm/api/packages/req_managed_agents/releases/0.12.0" "$(cat "$run/argv")"
exit $fail
