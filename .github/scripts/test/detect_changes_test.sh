#!/usr/bin/env bash
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/detect-changes.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want '$2', got '$3')"; fail=1; fi; }
sel() { printf '%s\n' "$@" | bash "$SCRIPT" 2>/dev/null | sed '/^matrix=/d' | tr '\n' ' ' | sed 's/ $//'; }
BOTH='packages=["req_managed_agents","req_managed_agents_host"]'
THREE='packages=["aws_event_stream","req_managed_agents","req_managed_agents_host"]'
ALL="$THREE root=true"

check "a codec change tests its consumers" "$THREE root=false" "$(sel aws_event_stream/lib/aws_event_stream.ex)"

check "an RMA change runs both packages" "$BOTH root=false" "$(sel req_managed_agents/lib/x.ex)"
check "an RMAH change runs RMAH only" 'packages=["req_managed_agents_host"] root=false' "$(sel req_managed_agents_host/lib/x.ex)"
check "a package README is a package change" 'packages=["req_managed_agents_host"] root=false' "$(sel req_managed_agents_host/README.md)"
for p in mix.exs .github/workflows/ci.yml .hygiene/forbidden-paths.txt .githooks/pre-push .gitignore LICENSE; do
  check "root $p runs everything" "$ALL" "$(sel "$p")"
done
check "root docs only run nothing" 'packages=[] root=false' "$(sel README.md CONTRIBUTING.md .claude/CLAUDE.md)"
check "an unlisted root file runs everything" "$ALL" "$(sel NOTICE)"
err=$(printf 'NOTICE\n' | bash "$SCRIPT" 2>&1 >/dev/null)
check "a fall-through is logged" yes "$(grep -q "no rule for 'NOTICE'" <<<"$err" && echo yes || echo no)"
check "an empty diff runs everything" "$ALL" "$(printf '' | bash "$SCRIPT" 2>/dev/null | sed '/^matrix=/d' | tr '\n' ' ' | sed 's/ $//')"
check "--all runs everything" "$ALL" "$(bash "$SCRIPT" --all </dev/null 2>/dev/null | sed '/^matrix=/d' | tr '\n' ' ' | sed 's/ $//')"

# A rename across the package boundary must select both sides. The move goes
# from RMA into RMAH: with rename detection, --name-only lists only the RMAH
# side, and RMA, which lost the file, would not be tested.
# The fixture repo ignores the runner's git config (signing, hooks, templates)
# and removes itself.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
( cd "$d" && git init -q && mkdir -p req_managed_agents/lib && echo "defmodule X, do: nil" > req_managed_agents/lib/x.ex \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm a && mkdir -p req_managed_agents_host/lib \
  && git mv req_managed_agents/lib/x.ex req_managed_agents_host/lib/x.ex && git -c user.email=t@t -c user.name=t commit -qm b )
base=$(git -C "$d" rev-parse HEAD~1); head=$(git -C "$d" rev-parse HEAD)
check "a cross-package rename selects both" "$BOTH root=false" "$( (cd "$d" && bash "$SCRIPT" --diff "$base" "$head") 2>/dev/null | sed '/^matrix=/d' | tr '\n' ' ' | sed 's/ $//')"
rc=0; ( cd "$d" && bash "$SCRIPT" --diff "$base" 0000000000000000000000000000000000000000 ) >/dev/null 2>&1 || rc=$?
check "a failed git diff fails the script" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
rc=0; err=$(bash "$SCRIPT" --dif </dev/null 2>&1 >/dev/null) || rc=$?
check "an unknown flag is rejected" yes "$([ "$rc" -ne 0 ] && grep -q "unknown argument '--dif'" <<<"$err" && echo yes || echo no)"

# git quotes a non-ASCII path ("caf\303\251.ex") unless core.quotePath is off,
# and a quoted path matches no rule.
( cd "$d" && mkdir -p req_managed_agents_host/lib && echo "defmodule Y, do: nil" > "req_managed_agents_host/lib/café.ex" \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm c )
check "a non-ASCII path matches its package rule" 'packages=["req_managed_agents_host"] root=false' "$( (cd "$d" && bash "$SCRIPT" --diff "$head" "$(git rev-parse HEAD)") 2>/dev/null | sed '/^matrix=/d' | tr '\n' ' ' | sed 's/ $//')"
matrix=$(printf 'aws_event_stream/lib/aws_event_stream.ex\n' | bash "$SCRIPT" 2>/dev/null | sed -n 's/^matrix=//p')
legs=$(jq -r '.include[] | [.package, .elixir, .otp] | join("/")' <<<"$matrix")
check "codec and consumers retain their own compiler floors" "$(printf 'aws_event_stream/1.18/27\naws_event_stream/1.20/29\nreq_managed_agents/1.20/28\nreq_managed_agents/1.20/29\nreq_managed_agents_host/1.20/28\nreq_managed_agents_host/1.20/29')" "$legs"
matrix=$(printf 'req_managed_agents_host/lib/x.ex\n' | bash "$SCRIPT" 2>/dev/null | sed -n 's/^matrix=//p')
check "a host-only selection never adds a codec floor job" 'req_managed_agents_host req_managed_agents_host' "$(jq -r '[.include[].package] | join(" ")' <<<"$matrix")"
workflow=$(ruby "$(dirname "$0")/workflow_json.rb" "$(dirname "$SCRIPT")/../workflows/ci.yml") || exit 1
check "the test matrix consumes the selected package/compiler legs" \
  '${{ fromJSON(needs.detect-changes.outputs.matrix).include }}' \
  "$(jq -r '.jobs.test.strategy.matrix.include' <<<"$workflow")"
check "setup-beam uses each selected Elixir version" '${{ matrix.elixir }}' \
  "$(jq -r '.jobs.test.steps[] | select(.uses // "" | startswith("erlef/setup-beam@")) | .with["elixir-version"]' <<<"$workflow")"
check "setup-beam uses each selected OTP version" '${{ matrix.otp }}' \
  "$(jq -r '.jobs.test.steps[] | select(.uses // "" | startswith("erlef/setup-beam@")) | .with["otp-version"]' <<<"$workflow")"
check "each matrix leg tests its selected package directory" '${{ matrix.package }}' \
  "$(jq -r '.jobs.test.defaults.run["working-directory"]' <<<"$workflow")"
exit $fail
