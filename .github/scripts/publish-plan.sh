#!/usr/bin/env bash
# Resolve package membership through the root Mix selector; publish order is
# deliberately independent of release groups.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: publish-plan.sh TAG" >&2; exit 1; }
tag="$1"
cd "$(dirname "$0")/../.."
packages="$(mix release_packages "$tag")"
[ -n "$packages" ] || { echo "publish-plan: empty release set" >&2; exit 1; }
if [[ "$tag" = v* ]]; then
  kind=lockstep
  version="${tag#v}"
else
  version="${tag#*-v}"
  if [ "${tag%%-v*}" = aws_event_stream ]; then kind=independent; else kind=patch; fi
fi
printf 'kind=%s\nversion=%s\npackages=%s\n' "$kind" "$version" "$(tr '\n' ' ' <<<"$packages" | sed 's/ $//')"
