#!/usr/bin/env bash
# The one required CI check. Reads $NEEDS (the workflow's toJSON(needs)) and
# passes only when detect-changes succeeded and every other job either
# succeeded or was skipped because detect-changes did not select it. A skip of
# a selected job is red: a gate that reads "skipped" as "fine" passes on nothing.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lines="$(jq -r -f "$here/ci-ok.jq" <<<"${NEEDS:-}")" || { echo "ci-ok: FAIL: cannot read needs" >&2; exit 1; }
printf '%s\n' "$lines"
[ -n "$lines" ] || { echo "ci-ok: FAIL: no jobs to judge" >&2; exit 1; }
if grep -q '^FAIL' <<<"$lines"; then exit 1; fi
