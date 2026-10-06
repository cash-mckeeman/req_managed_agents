#!/usr/bin/env bash
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/publish-package.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want '$2', got '$3')"; fail=1; fi; }
# curl, mix and elixir are stubs: curl answers $FAKE_HTTP (exiting $FAKE_CURL_RC),
# and mix and elixir only record how they were called.
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
mkdir -p "$d/bin" "$d/repo/req_managed_agents" "$d/repo/req_managed_agents_host"
printf '#!/usr/bin/env bash\nprintf "%%s" "$FAKE_HTTP"; exit "${FAKE_CURL_RC:-0}"\n' > "$d/bin/curl"
printf '#!/usr/bin/env bash\necho "mix RMA_PUBLISH=${RMA_PUBLISH:-} MIX_ENV=${MIX_ENV:-} $*" >> "$CALLS"\n' > "$d/bin/mix"
printf '#!/usr/bin/env bash\necho "elixir $*" >> "$CALLS"\n' > "$d/bin/elixir"
chmod +x "$d/bin/"*
# publish <package> <kind> <dry run> <hex.pm HTTP code> [curl exit]: prints the exit code.
# The Hex key is "key" unless KEY is set around the call; KEY=UNSET leaves it unset.
publish() {
  : > "$d/calls"; : > "$d/summary"
  local key="${KEY-key}"; [ "$key" = UNSET ] && key=""
  ( cd "$d/repo"
    export HEX_API_KEY="$key"; [ "${KEY-key}" != UNSET ] || unset HEX_API_KEY
    PATH="$d/bin:$PATH" CALLS="$d/calls" GITHUB_STEP_SUMMARY="$d/summary" RUNNER_TEMP="$d" \
    KIND="$2" VERSION=0.12.1 DRY_RUN="$3" FAKE_HTTP="$4" FAKE_CURL_RC="${5:-0}" bash "$SCRIPT" "$1" >/dev/null 2>&1 )
  echo $?
}
ran() { grep -c "$1" "$d/calls"; }

check "on Hex: exits 0" 0 "$(publish req_managed_agents_host patch 0 200)"
check "on Hex: nothing runs" 0 "$(ran .)"
check "on Hex: the summary says skipped" 1 "$(grep -c 'skipped, already on Hex' "$d/summary")"
for answer in "503 0" "429 0" "000 6"; do
  read -r code rc <<<"$answer"
  check "hex.pm HTTP $code (curl exit $rc): fails" 1 "$([ "$(publish req_managed_agents_host patch 0 "$code" "$rc")" -ne 0 ] && echo 1 || echo 0)"
  check "hex.pm HTTP $code (curl exit $rc): nothing runs" 0 "$(ran .)"
done
for k in "" UNSET; do
  check "a real run with the key '${k:-empty}': fails" 1 "$([ "$(KEY="$k" publish req_managed_agents_host patch 0 404)" -ne 0 ] && echo 1 || echo 0)"
  check "a real run with the key '${k:-empty}': nothing runs" 0 "$(ran .)"
  check "a real run with the key '${k:-empty}': never publishes" 0 "$(ran hex.publish)"
done
check "a dry run needs no key" 0 "$(KEY= publish req_managed_agents lockstep 1 404)"
check "a dry run exits 0" 0 "$(publish req_managed_agents lockstep 1 404)"
check "a dry run checks the tarball" 1 "$(ran "elixir .*check_package.exs")"
check "a dry run never publishes" 0 "$(ran hex.publish)"
check "a host patch tests at the floor first" "mix RMA_PUBLISH=floor MIX_ENV= deps.get" \
  "$(publish req_managed_agents_host patch 1 404 >/dev/null; head -1 "$d/calls")"
check "a host patch runs the floor suite" 1 "$(ran "RMA_PUBLISH=floor MIX_ENV=test test")"
check "a real run publishes from Hex deps" 1 "$(publish req_managed_agents lockstep 0 404 >/dev/null; ran "RMA_PUBLISH=1 MIX_ENV= hex.publish --yes")"
exit $fail
