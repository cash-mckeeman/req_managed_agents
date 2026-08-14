#!/usr/bin/env bash
# Scan a git repo's tracked files for hygiene violations.
# Exit 0 = clean, 1 = violations found (printed to stderr).
set -u
DIR="."
[ "${1:-}" = "--dir" ] && { DIR="$2"; shift 2; }
cd "$DIR" || { echo "cannot cd $DIR" >&2; exit 2; }

# Locate pattern files: prefer an installed .hygiene/, else the directory this
# script was invoked from (the control-plane repo's guardrails/).
if [ -d .hygiene ]; then CFG=".hygiene"; else CFG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; fi
PATHS="$CFG/forbidden-paths.txt"; ALLOW="$CFG/allowed-aws-accounts.txt"

# Content patterns are a *set* of files, not one file:
#
#   forbidden-content.txt          every repo, public or private
#   forbidden-content-public.txt   public-bound repos only
#
# The rule being enforced is already per-visibility — CLAUDE.md permits the
# control plane's name and its doc-tree paths in a private repo and forbids
# them in a public one — so the pattern set is split the same way. Which files
# a repo carries is decided once, by `setup-repo.sh <repo> <slug> <mode>`.
#
# Fail closed: this directory (the control-plane checkout) carries both files,
# so running the scanner by hand against an uninstalled tree applies the strict
# public set. Relaxation only happens where it was explicitly installed.
CONTENT_FILES=( "$CFG"/forbidden-content*.txt )
[ -e "${CONTENT_FILES[0]}" ] || { echo "preflight: no forbidden-content*.txt in $CFG" >&2; exit 2; }

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

# --- Ask the tool that actually knows what is tracked. -----------------------
# In a jj repo, `git ls-files` does not answer "what is tracked" — it answers
# "what is in git's index", and in a colocated repo those diverge in both
# directions. Measured across two real repos, all four figures anchored:
#
#                                    git ls-files   jj file list   HEAD tree
#   colocated root (repo A)                10,702            257         257
#   repo A workspace                          282            277           0
#   colocated root (repo B) workspace           0            841           0
#
# At a colocated root the index had accumulated 10,445 entries under
# .claude/worktrees/ from a stray `git add` — a 40x over-scan that reports
# other lanes' scratch as repository content. From a workspace the same command
# returns 0 where the parent index is clean, and a phantom 282 where it is not.
# Neither number is the tracked file set. jj is right in every row.
#
# So prefer jj whenever this is a jj repo at all, not merely when `.git` is
# absent. Plain-git checkouts (CI) still take the git path, where it is correct.
#
# Then refuse to pass vacuously. A hygiene gate that cannot tell "clean" from
# "did not look" is worse than no gate, because it gets quoted as evidence.
if [ -d .jj ]; then
  FILES="$(jj file list 2>/dev/null)"
  SCANNER="jj"
else
  FILES="$(git ls-files 2>/dev/null)"
  SCANNER="git"
fi
FILES="$(printf '%s\n' "$FILES" | grep -Ev '^(\.hygiene/|guardrails/)$|^(\.hygiene/|guardrails/)' || true)"

if [ -z "$FILES" ]; then
  echo "preflight: scanned 0 files via $SCANNER in $(pwd) — refusing to report clean." >&2
  echo "preflight: nothing here is tracked by $SCANNER. If this is a jj workspace," >&2
  echo "preflight: install jj; otherwise run this from the repo root." >&2
  exit 2
fi

viol=0

# 1. Forbidden paths (git-tracked files, excluding the scanner's own config dirs).
# Portability note: bash 3.2 (macOS default) has no `mapfile`. We avoid building
# a file-list array and instead stream `git ls-files` through process substitution
# (supported since old bash, unlike mapfile) so `viol` set in the loop body persists
# in this shell rather than a lost pipeline subshell.
while IFS= read -r pat; do
  case "$pat" in ''|'#'*) continue ;; esac
  while IFS= read -r f; do
    if printf '%s\n' "$f" | grep -Eq "$pat"; then echo "PATH  $f  (matches /$pat/)" >&2; viol=1; fi
  done < <(printf '%s\n' "$FILES")
done < "$PATHS"

# 2. Forbidden content, over every installed pattern file.
#
# Judge by what grep *wrote*, never by what xargs *returned*. `xargs` exits
# non-zero if ANY invocation did, and `grep` exits 1 on "no match" — so the
# moment the file list is long enough to split into more than one batch, a
# batch that matches nothing makes the whole pipeline look like "no match" and
# the real hits sitting in the output file are discarded unread. Measured on
# a real repo's tree: 10,698 files, 3 batches, one content pattern matched 4
# lines (including a live leak) and the old `if xargs …` guard evaluated false.
#
# `-H` because grep omits the filename when a batch happens to hold exactly one
# file, which turns a violation into an unattributable line number.
while IFS= read -r pat; do
  case "$pat" in ''|'#'*) continue ;; esac
  printf '%s\n' "$FILES" | tr '\n' '\0' | xargs -0 grep -HnE "$pat" >"$TMP" 2>/dev/null
  if [ -s "$TMP" ]; then sed 's/^/CONTENT /' "$TMP" >&2; viol=1; fi
done < <(cat "${CONTENT_FILES[@]}")

# 3. AWS account ids in ARNs, minus allowlist.
allow_re="$(paste -sd'|' "$ALLOW")"
printf '%s\n' "$FILES" | tr '\n' '\0' | xargs -0 grep -hoE 'arn:aws:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:' 2>/dev/null \
  | grep -oE '[0-9]{12}' | sort -u | grep -Evx "$allow_re" >"$TMP"
if [ -s "$TMP" ]; then
  while read -r acct; do echo "AWS   disallowed account id $acct in an ARN" >&2; done < "$TMP"
  viol=1
fi

exit $viol
