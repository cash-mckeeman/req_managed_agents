#!/usr/bin/env bash
# Fails unless the installed Hex is 2.6.0 or newer, the first release that can
# exchange the job's GitHub OIDC token for a publish token (workload identity).
# Older Hex would only fail later, at publish time.
set -euo pipefail
v="$(mix hex.info | sed -n 's/^Hex: *//p')"
if printf '%s\n' "$v" | awk -F. '
  $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && ($1 > 2 || ($1 == 2 && $2 >= 6)) { ok = 1 }
  END { exit !ok }'; then
  echo "Hex $v supports workload identity"
else
  echo "::error::Hex '${v:-unknown}' is older than 2.6.0; workload identity needs 2.6.0"
  exit 1
fi
