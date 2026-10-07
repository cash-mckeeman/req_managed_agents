#!/usr/bin/env bash
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/publish-plan.sh"
ORDER=(req_managed_agents req_managed_agents_host)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want '$2', got '$3')"; fail=1; fi; }
plan() { bash "$SCRIPT" "$1" "${ORDER[@]}" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
rejects() { bash "$SCRIPT" "$1" "${ORDER[@]}" >/dev/null 2>&1 && echo accepted || echo rejected; }

check "v0.12.0 is a lockstep minor" "kind=lockstep version=0.12.0 packages=req_managed_agents req_managed_agents_host" "$(plan v0.12.0)"
check "a host patch selects the host only" "kind=patch version=0.12.1 packages=req_managed_agents_host" "$(plan req_managed_agents_host-v0.12.1)"
check "an RMA patch selects RMA only" "kind=patch version=0.12.3 packages=req_managed_agents" "$(plan req_managed_agents-v0.12.3)"
for t in v0.12.1 req_managed_agents_host-v0.12.0 v0.12.0-rc.1 foo-v0.12.1 v01.12.0 0.12.0 v0.12 req_managed_agents-v0.12.1-rc.1; do
  check "$t is rejected" rejected "$(rejects "$t")"
done
bash "$SCRIPT" v0.12.0 >/dev/null 2>&1; check "an empty publish order is rejected" 1 "$([ $? -ne 0 ] && echo 1 || echo 0)"
exit $fail
