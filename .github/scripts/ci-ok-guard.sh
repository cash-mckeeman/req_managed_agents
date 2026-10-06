#!/usr/bin/env bash
# ci-ok-guard.sh <owner/repo> <sha>
# Passes only on a completed ci-ok with conclusion success on exactly <sha>.
# Several runs (a re-run): once none is still running, the latest by
# completed_at decides. No registered run and pending runs are waited on within the same deadline;
# neither is a success. A failed latest run fails immediately.
set -euo pipefail
repo="$1"; sha="$2"
here="$(cd "$(dirname "$0")" && pwd)"
wait_s="${CI_OK_WAIT_SECONDS:-1200}"; poll_s="${CI_OK_POLL_SECONDS:-30}"
case "$wait_s" in *[!0-9]*) echo "ci-ok: CI_OK_WAIT_SECONDS must be a non-negative integer, not '$wait_s'" >&2; exit 2 ;; esac
wait_s=$((10#$wait_s))
deadline=$(( $(date +%s) + wait_s ))
while :; do
  verdict="$(gh api "repos/$repo/commits/$sha/check-runs?check_name=ci-ok&filter=all&per_page=100" | jq -r -f "$here/ci-ok-guard.jq")"
  case "$verdict" in
    pass) echo "ci-ok: success on $sha"; exit 0 ;;
    pending|missing)
      if [ "$(date +%s)" -ge "$deadline" ]; then echo "ci-ok: $verdict on $sha after ${wait_s}s" >&2; exit 1; fi
      echo "ci-ok: $verdict on $sha; next look in ${poll_s}s"; sleep "$poll_s" ;;
    *) echo "ci-ok: $verdict on $sha" >&2; exit 1 ;;
  esac
done
