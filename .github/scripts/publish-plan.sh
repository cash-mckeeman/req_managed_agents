#!/usr/bin/env bash
# publish-plan.sh <tag> <package>...   (the packages in publish order)
# Prints the publish plan for a tag as step outputs. Exactly two tag forms:
#   vX.Y.0             every package in the publish order: a lockstep minor
#   <package>-vX.Y.Z   that package alone, Z > 0: a per-package patch
# Anything else, pre-releases included, is rejected before anything runs.
set -euo pipefail
tag="$1"; shift
[ $# -gt 0 ] || { echo "publish-plan: empty publish order" >&2; exit 1; }
num='(0|[1-9][0-9]*)'
if [[ "$tag" =~ ^v${num}\.${num}\.${num}$ ]]; then
  if [ "${BASH_REMATCH[3]}" != 0 ]; then
    echo "publish-plan: $tag: a v* tag is a lockstep minor and ends in .0; tag a patch <package>-${tag}" >&2; exit 1
  fi
  echo "kind=lockstep"; echo "version=${tag#v}"; echo "packages=$*"
elif [[ "$tag" =~ ^([a-z_]+)-v${num}\.${num}\.${num}$ ]]; then
  pkg="${BASH_REMATCH[1]}"
  if [ "${BASH_REMATCH[4]}" = 0 ]; then
    echo "publish-plan: $tag: minors are lockstep; tag v${tag#*-v}" >&2; exit 1
  fi
  listed=false; for p in "$@"; do [ "$p" = "$pkg" ] && listed=true; done
  [ "$listed" = true ] || { echo "publish-plan: $tag: $pkg is not in the publish order ($*)" >&2; exit 1; }
  echo "kind=patch"; echo "version=${tag#*-v}"; echo "packages=$pkg"
else
  echo "publish-plan: $tag is neither vX.Y.0 nor <package>-vX.Y.Z" >&2; exit 1
fi
