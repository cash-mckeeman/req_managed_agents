#!/usr/bin/env bash
# Scheduled maintainer check: drift is reported without committing new vectors.
set -euo pipefail
cd "$(dirname "$0")/../../aws_event_stream"
d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
mix deps.get
set +e
mix aws_event_stream.sync_fixtures | tee "$d/sync_summary.txt"
code=${PIPESTATUS[0]}
set -e
case "$code" in
  0) exit 0 ;;
  2) ;;
  *) echo "sync task failed unexpectedly (exit $code)" >&2; exit "$code" ;;
esac
if mix test; then
  headline='**mix test PASSES against the new vectors** — refreshing the fixtures is routine.'
else
  headline='**mix test FAILS against the new vectors** — a codec change may be needed (see workflow logs).'
fi
{
  echo 'The upstream aws-sdk-go-v2 event-stream test corpus changed.'
  echo
  echo "$headline"
  echo
  echo '```'
  cat "$d/sync_summary.txt"
  echo '```'
  echo
  echo 'To refresh: run `mix aws_event_stream.sync_fixtures` from `aws_event_stream/`, review, and commit.'
} > "$d/issue_body.md"
gh label create upstream-fixtures-drift --force \
  --description 'Upstream AWS SDK test vectors drifted' --color D93F0B
existing=$(gh issue list --label upstream-fixtures-drift --state open \
  --json number --jq '.[0].number // empty')
if [ -n "$existing" ]; then
  gh issue comment "$existing" --body-file "$d/issue_body.md"
else
  gh issue create --title 'Upstream event-stream test vectors changed' \
    --label upstream-fixtures-drift --body-file "$d/issue_body.md"
fi
