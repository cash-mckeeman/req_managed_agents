#!/usr/bin/env bash
# publish-package.sh <package>, run from the repository root.
# Env: KIND (lockstep|patch), VERSION, DRY_RUN (1|0), HEX_API_KEY (real runs only).
# Order: skip if already on Hex (a rerun after a partial failure is safe) ->
# patch floor (host patches) -> suite against Hex deps -> tarball check -> publish.
set -euo pipefail
pkg="$1"; here="$(cd "$(dirname "$0")" && pwd)"; summary="${GITHUB_STEP_SUMMARY:-/dev/stderr}"
cd "$pkg"

# Anything but the two values the workflow emits is a mistake, and a mistaken
# DRY_RUN must not fall through to a real publish.
case "${DRY_RUN-}" in 0|1) ;; *) echo "publish-package: DRY_RUN must be 0 or 1, not '${DRY_RUN-}'" >&2; exit 1 ;; esac
case "${KIND-}" in lockstep|patch) ;; *) echo "publish-package: KIND must be lockstep or patch, not '${KIND-}'" >&2; exit 1 ;; esac

if [ "$DRY_RUN" != 1 ] && [ -z "${HEX_API_KEY:-}" ]; then
  echo "publish-package: HEX_API_KEY is empty on a real run for $pkg" >&2; exit 1
fi

# A plain assignment, so set -e stops on an on-hex error. Inside `[ ... ]` the
# error would read as "not on Hex" and the publish would go ahead.
on_hex="$(bash "$here/on-hex.sh" "$pkg" "$VERSION")"
if [ "$on_hex" = yes ]; then
  echo "- $pkg $VERSION: skipped, already on Hex" >> "$summary"; exit 0
fi

if [ "$pkg" = req_managed_agents_host ] && [ "$KIND" = patch ]; then
  echo "patch floor: building and testing against the lowest req_managed_agents this patch admits"
  RMA_PUBLISH=floor mix deps.get
  RMA_PUBLISH=floor MIX_ENV=test mix compile --warnings-as-errors
  RMA_PUBLISH=floor MIX_ENV=test mix test
  # The next suite must resolve current Hex deps rather than reuse the floor.
  RMA_PUBLISH=1 mix deps.unlock req_managed_agents
fi

if [ "$DRY_RUN" = 1 ] && [ "$pkg" = req_managed_agents_host ] && [ "$KIND" = lockstep ]; then
  echo "dry run: the Hex-resolved suite for $pkg needs req_managed_agents $VERSION on Hex; it runs on a real tag only" | tee -a "$summary"
else
  # A sibling published moments ago may still be propagating through the registry.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    RMA_PUBLISH=1 mix deps.get && break
    [ "$i" -lt 10 ] || { echo "deps.get failed 10 times, 30 s apart" >&2; exit 1; }
    sleep 30
  done
  RMA_PUBLISH=1 MIX_ENV=test mix test
fi

RMA_PUBLISH=1 mix hex.build --output "$RUNNER_TEMP/$pkg.tar"
elixir "$here/check_package.exs" "$RUNNER_TEMP/$pkg.tar"

if [ "$DRY_RUN" = 1 ]; then echo "- $pkg $VERSION: dry run, would publish" >> "$summary"; exit 0; fi
RMA_PUBLISH=1 mix hex.publish --yes
echo "- $pkg $VERSION: published" >> "$summary"
