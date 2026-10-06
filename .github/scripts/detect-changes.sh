#!/usr/bin/env bash
# Which CI jobs a change needs, as GitHub step outputs:
#   packages=<JSON array, publish order>   root=<true|false>
# Input: --all; --diff <base> <head>; or changed paths on stdin, one per line.
# A path no rule names selects everything and is logged, and so does an empty
# list: a selection that can come out empty must never read as "nothing to test".
set -euo pipefail

if [ "${1:-}" = --all ]; then
  paths=""
  echo "detect-changes: --all; selecting everything" >&2
elif [ "${1:-}" = --diff ]; then
  # --no-renames lists both sides of a rename, so a move across the package
  # boundary selects both packages.
  paths="$(git -c core.quotePath=false diff --name-only --no-renames "$2...$3")"
elif [ -n "${1:-}" ]; then
  echo "detect-changes: unknown argument '$1'; usage: --all | --diff <base> <head> | paths on stdin" >&2
  exit 2
else
  paths="$(cat)"
fi

rma=false rmah=false root=false any=false
while IFS= read -r p; do
  [ -n "$p" ] || continue
  any=true
  case "$p" in
    req_managed_agents/*) rma=true; rmah=true ;;
    req_managed_agents_host/*) rmah=true ;;
    mix.exs|.gitignore|LICENSE|.github/*|.hygiene/*|.githooks/*) rma=true; rmah=true; root=true ;;
    README.md|CONTRIBUTING.md|.claude/*) ;;
    *) echo "detect-changes: no rule for '$p'; selecting everything" >&2; rma=true; rmah=true; root=true ;;
  esac
done <<<"$paths"

if [ "$any" = false ]; then
  [ "${1:-}" = --all ] || echo "detect-changes: no changed paths; selecting everything" >&2
  rma=true; rmah=true; root=true
fi

packages="["; sep=""
if [ "$rma" = true ]; then packages+="${sep}\"req_managed_agents\""; sep=","; fi
if [ "$rmah" = true ]; then packages+="${sep}\"req_managed_agents_host\""; fi
packages+="]"
echo "detect-changes: packages=$packages root=$root" >&2
echo "packages=$packages"
echo "root=$root"
