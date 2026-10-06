#!/usr/bin/env bash
# on-hex.sh <package> <version>: prints yes or no. Any other answer from hex.pm
# is an error, never "no": a misread "no" would re-run a publish.
# Sourceable: the test loads hex_answer without running curl or setting -e.
hex_answer() {
  case "$1" in
    200) echo yes ;;
    404) echo no ;;
    *) echo "on-hex: hex.pm answered HTTP $1" >&2; return 1 ;;
  esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  code="$(curl -s -o /dev/null -w '%{http_code}' "https://hex.pm/api/packages/$1/releases/$2")"
  hex_answer "$code"
fi
