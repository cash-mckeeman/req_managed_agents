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
exit $fail
