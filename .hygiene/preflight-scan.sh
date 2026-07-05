#!/usr/bin/env bash
# Scan a git repo's tracked files for hygiene violations.
# Exit 0 = clean, 1 = violations found (printed to stderr).
set -u
DIR="."
[ "${1:-}" = "--dir" ] && { DIR="$2"; shift 2; }
cd "$DIR" || { echo "cannot cd $DIR" >&2; exit 2; }

# Locate pattern files: prefer installed .hygiene/, else biai-ops guardrails/.
if [ -d .hygiene ]; then CFG=".hygiene"; else CFG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; fi
PATHS="$CFG/forbidden-paths.txt"; CONTENT="$CFG/forbidden-content.txt"; ALLOW="$CFG/allowed-aws-accounts.txt"

viol=0

# 1. Forbidden paths (git-tracked files, excluding the scanner's own config dirs).
# Portability note: bash 3.2 (macOS default) has no `mapfile`. We avoid building
# a file-list array and instead stream `git ls-files` through process substitution
# (supported since old bash, unlike mapfile) so `viol` set in the loop body persists
# in this shell rather than a lost pipeline subshell.
while IFS= read -r pat; do
  [ -z "$pat" ] && continue
  while IFS= read -r f; do
    if printf '%s\n' "$f" | grep -Eq "$pat"; then echo "PATH  $f  (matches /$pat/)" >&2; viol=1; fi
  done < <(git ls-files | grep -Ev '^(\.hygiene/|guardrails/)')
done < "$PATHS"

# 2. Forbidden content. Let git grep do the path exclusion directly via pathspec
# magic so we never need a materialized file list.
while IFS= read -r pat; do
  [ -z "$pat" ] && continue
  if git grep -nE "$pat" -- ':(exclude).hygiene/' ':(exclude)guardrails/' >/tmp/hg.$$ 2>/dev/null; then
    sed 's/^/CONTENT /' /tmp/hg.$$ >&2; viol=1
  fi
  rm -f /tmp/hg.$$
done < "$CONTENT"

# 3. AWS account ids in ARNs, minus allowlist.
allow_re="$(paste -sd'|' "$ALLOW")"
if git grep -hoE 'arn:aws:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:' -- ':(exclude).hygiene/' ':(exclude)guardrails/' 2>/dev/null \
   | grep -oE '[0-9]{12}' | sort -u | grep -Evx "$allow_re" >/tmp/hga.$$; then
  if [ -s /tmp/hga.$$ ]; then
    while read -r acct; do echo "AWS   disallowed account id $acct in an ARN" >&2; done < /tmp/hga.$$
    viol=1
  fi
fi
rm -f /tmp/hga.$$

exit $viol
