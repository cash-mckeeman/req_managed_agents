#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
mkdir "$d/bin"
cat > "$d/bin/mix" <<'STUB'
#!/usr/bin/env bash
[ "$PWD" = "$EXPECTED_CODEC" ] || { echo 'wrong package directory' >&2; exit 99; }
echo "$*" >> "$CALLS"
case "$*" in
  deps.get) exit 0 ;;
  aws_event_stream.sync_fixtures) echo 'fixture changes'; exit "$SYNC_CODE" ;;
  test) echo 'codec result'; exit "$TEST_CODE" ;;
  *) exit 98 ;;
esac
STUB
cat > "$d/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$ISSUES"
case "$*" in
  'issue list '*) printf '%s' "$EXISTING_ISSUE" ;;
  'issue create '*|'issue comment '*)
    while [ "$1" != --body-file ]; do shift; done
    cp "$2" "$BODY" ;;
esac
STUB
chmod +x "$d/bin/"*
run_watch() {
  : > "$d/calls"; : > "$d/issues"; : > "$d/body"
  PATH="$d/bin:$PATH" EXPECTED_CODEC="$root/aws_event_stream" CALLS="$d/calls" ISSUES="$d/issues" BODY="$d/body" \
    SYNC_CODE="$1" TEST_CODE="$2" EXISTING_ISSUE="$3" bash "$root/.github/scripts/watch-fixtures.sh" > "$d/output" 2>&1
}
run_watch 0 0 ''
if grep -q '^test$' "$d/calls"; then echo 'FAIL: unchanged fixtures ran tests' >&2; exit 1; fi
[ ! -s "$d/issues" ]
echo 'ok: unchanged fixtures do not test or open issues'
run_watch 2 0 ''
grep -q '^test$' "$d/calls"
grep -q '^issue create ' "$d/issues"
grep -q 'PASSES' "$d/body"
grep -q 'upstream-fixtures-drift' "$d/issues"
echo 'ok: drift tests the codec and creates a labeled issue'
run_watch 2 1 42
grep -q '^issue comment 42 ' "$d/issues"
if grep -q '^issue create ' "$d/issues"; then echo 'FAIL: existing drift issue duplicated' >&2; exit 1; fi
grep -q 'FAILS' "$d/body"
echo 'ok: codec failure updates the existing drift issue'
if run_watch 1 0 ''; then echo 'FAIL: upstream sync failure passed' >&2; exit 1; fi
[ ! -s "$d/issues" ]
echo 'ok: upstream failure fails without filing a drift issue'
