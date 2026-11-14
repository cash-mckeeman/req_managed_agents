#!/usr/bin/env bash
# The Hex version guard, run against a stub `mix hex.info`.
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/hex-workload-identity.sh"
fail=0
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
mkdir -p "$d/bin"
printf '#!/usr/bin/env bash\nprintf "%%s" "$FAKE_HEX_INFO"\n' > "$d/bin/mix"
chmod +x "$d/bin/mix"
# guard <hex.info output>: prints the guard's exit code.
guard() { ( PATH="$d/bin:$PATH" FAKE_HEX_INFO="$1" bash "$SCRIPT" >/dev/null 2>&1 ); echo $?; }
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want '$2', got '$3')"; fail=1; fi; }
check "Hex 2.5.9 is refused" 1 "$(guard $'Hex: 2.5.9\n')"
check "Hex 2.0.0 is refused" 1 "$(guard $'Hex: 2.0.0\n')"
check "Hex 1.20.0 is refused" 1 "$(guard $'Hex: 1.20.0\n')"
check "Hex 2.6.0 is accepted" 0 "$(guard $'Hex: 2.6.0\n')"
check "Hex 2.10.1 is accepted (10 > 6, not a string compare)" 0 "$(guard $'Hex: 2.10.1\n')"
check "Hex 3.0.0 is accepted" 0 "$(guard $'Hex: 3.0.0\n')"
check "Hex 2.6.0-dev is accepted" 0 "$(guard $'Hex: 2.6.0-dev\n')"
check "extra hex.info lines are ignored" 0 "$(guard $'Hex:    2.6.1\nElixir: 1.20\n')"
check "no Hex line is refused" 1 "$(guard $'nothing\n')"
check "empty output is refused" 1 "$(guard '')"
exit $fail
