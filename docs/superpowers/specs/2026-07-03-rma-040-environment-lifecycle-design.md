# RMA 0.4 — Environment Lifecycle Design (MIM-69 / MIM-70 / MIM-71)

**Date:** 2026-07-03
**Status:** Approved design (brainstorm complete)
**Linear:** project "RMA 0.4 — environment lifecycle" — MIM-69 (blocks 70), MIM-70 (blocks 71), MIM-71. GitHub: closes #32, #33, #36.
**Release thesis:** environments (and, later, agents) are **images**; sessions are the
**containers**. Provisioning grows from "idempotent within one BEAM" to declarative,
persistent, content-addressed, and explicitly garbage-collected — the Docker mental model,
honestly mapped onto the Managed Agents API.

---

## The model (governs every design choice below)

| Docker | RMA |
|---|---|
| Dockerfile | env spec (canonical map) |
| image digest | spec hash — the **identity**, content-addressed |
| repository | base name (`data_analysis`) |
| `repo@digest` | provider-side name `<base>_<digest8>` |
| `docker build` (cached) | `ensure_environment/3` — build-if-absent, **never rebuilds on a hit** |
| `repo:tag` (movable) | Store-backed tag → digest pointer |
| `docker run` | `create_session` — ephemeral, references an image |
| `docker image prune` | `prune_environments/3` — **explicit** GC, never automatic |

Consequences:

- **There is no drift and no `on_drift`** (revises the shape proposed in GH #33): a changed
  spec is a *new image* ensured alongside the old. Supersession is a tag move; destruction
  is a deliberate prune. Nothing is ever auto-archived (archives are permanent).
- **The API already agrees:** sessions are the only born-and-die resource; agents are
  versioned-immutable (`update_agent` mints a version); environments have no update-in-place
  — 0.4 stops pretending otherwise.
- **Bedrock needs nothing new:** the digest-named harness (`harness_<hash8>`) already IS
  this model. 0.4 brings the Claude environment resource up to the same standard.
- **Foreshadowing (recorded, out of scope):** agents unify under the same image vocabulary
  in a later release; the harness/agent/environment trio then share one
  build/tag/run/prune surface.
- **Operational discipline changes now:** canary/QA reuse pinned images across runs (ensure
  hits after the first run); only sessions churn; a prune leg cleans up superseded
  generations.

## Verified constraints

1. `Provisioner.ensure/3` hash: `sha256(term_to_binary({provider, spec}, deterministic))`,
   ETS-cached, ETS is "an in-process optimization, not the source of truth" (moduledoc).
   GH #32's Store behaviour proposal fits this exactly.
2. Environments: `create_environment/2` 409s on name collision; no update-in-place; the
   Managed Agents docs tell consumers to keep their own record of config per session —
   content-addressed names make the record self-describing server-side.
3. `list_environments/2` exists on `Client` + `Client.Behaviour` (recovery-by-name path).
4. Environment `packages` supports only `apt, cargo, gem, go, npm, pip` — no language
   runtimes beyond those managers (GH #36). mise installs Elixir 1.20/OTP 28 in ~15s in a
   cloud sandbox (consumer-verified); the bootstrap mechanics (pinned versions, host
   allowlist, UTF-8 locale) are runtime concerns, not app concerns.
5. **Unverified, gated:** the cloud attachment mechanism for a bootstrap (CMA skills API
   vs a mounted file resource + first-run instruction) — plan Task 1 is a live spike; no
   TDD task may depend on the mechanism before the spike reports.

## Decisions (from the brainstorm)

- **D1 — Release cut:** MIM-69 + 70 + 71, three dependency-ordered PRs, each closed by a
  QA-CHECKPOINT (the 0.3.0 delivery shape).
- **D2 — Batteries:** ship `Store.File` alongside the behaviour and the ETS default. DB
  stores remain consumer-land.
- **D3 — Image semantics** (supersedes GH #33's ensure/reconcile-with-drift): digest-named
  environments, no on_drift, explicit prune, supersession via tags.
- **D4 — Thin tags in 0.4:** store-entry pointers only (`tag:<base>:<name>` → digest),
  `tag/4` + `resolve/2`; prune's safety rule is *never prune a tagged digest*.
- **D5 — MIM-71 realization is spike-gated** (constraint 5); the spec fixes the *surface*
  (`runtimes:` on the env spec, library-owned bootstrap content under `priv/`), not the
  attachment mechanism.

---

## §1 MIM-69 — `Provisioner.Store` behaviour + `Store.ETS` + `Store.File`

```elixir
defmodule ReqManagedAgents.Provisioner.Store do
  @callback get(store_opts :: term(), key :: String.t()) :: {:ok, term()} | :miss
  @callback put(store_opts :: term(), key :: String.t(), value :: term()) :: :ok
  @callback delete(store_opts :: term(), key :: String.t()) :: :ok
end
```

- Keys are strings, namespaced by prefix: `"provision:" <> hash` (existing agent/harness
  handles), `"tag:" <> base <> ":" <> tag` (MIM-70). Namespacing lives in the callers, so
  the behaviour stays three verbs.
- `:store` option everywhere a cache is consulted: `{module, store_opts}`; default
  `{Store.ETS, table}` extracted from today's inline ETS logic — behavior-identical.
- `Store.File`: one JSON file (`path:` required). Atomic writes (write tmp + `File.rename`).
  Missing or corrupt file → treated as empty with one `Logger.warning`. **Single-writer
  assumption documented** (CLI/mix-task/cron usage; not a concurrent-fleet store). Values
  are JSON — handles are plain maps already; non-JSON-able values are a caller error.
- `ensure/3` and `evict/1` route through the configured store; hash derivation unchanged.
- Store failures are loud-but-safe: if `put` fails after a successful provider create, log
  and still return the handle — **provisioning truth beats cache truth**.

## §2 MIM-70 — environments as images

```elixir
{:ok, %{environment_id: id, name: name, digest: digest}} =
  Provisioner.ensure_environment(client, env_spec,
    name: "data_analysis",              # repository; default "env"
    store: {Store.File, path: "..."})   # default Store.ETS
```

- **Env spec** is a canonical map (`%{type:, packages:, networking:, runtimes: …}`) —
  hashed with the existing deterministic derivation; opaque beyond hashing and wire
  translation. `digest` = first 8 hex chars (harness_name precedent).
- **Name = `<base>_<digest8>`** — `repo@digest`. Never 409s across configs; a 409 means
  *this exact image already exists* and recovery is definitionally the right version.
- **Ensure flow:** store hit → handle. Miss → recover-by-name (`list_environments`, filter
  exact name, non-archived) → found: store + return. Absent → `create_environment` → store
  + return. Works with an empty store on a fresh machine.
- **Tags:** `Provisioner.tag(base, tag, digest_or_handle, store: …)` writes
  `tag:<base>:<tag>` → digest; `Provisioner.resolve("data_analysis:prod", store: …)` →
  `{:ok, handle} | {:error, :unknown_tag}` (handle looked up via `provision:` entry or
  recovery-by-name). Atomic per the store's `put` (single-writer).
- **Prune:** `Provisioner.prune_environments(client, base, keep: n, store: …)`:
  lists `<base>_*` environments, orders by creation, keeps the newest `n` **plus** every
  tagged digest, archives the rest via `archive_environment`, deletes their `provision:`
  entries, and returns `{:ok, %{archived: [...], kept: [...]}}`. `keep:` has **no default**
  — deliberate friction on a permanent operation. Never touches tagged digests.
- Facade: `ReqManagedAgents.ensure_environment/3` delegating, consistent with
  `provision/3`'s placement.

## §3 MIM-71 — declared runtimes, spike-gated realization

- Spec surface: `runtimes: [%{lang: :elixir, version: "1.20", via: :mise}]` (list; `via`
  defaults `:mise`; `lang`/`version` required). Participates in the digest automatically —
  a runtime change is a new image, no extra machinery.
- Library-owned bootstrap content under `priv/runtime_bootstrap/`: the mise install
  script template (pinned-version rendering), the known-host allowlist that
  `ensure_environment` merges into `networking.allowed_hosts` when runtimes are declared
  and networking is `:limited`, and the locale/env flags Elixir needs.
- **Plan Task 1 (spike, live):** determine the attachment mechanism — candidates ranked:
  (a) CMA skills attachment if the API supports it cleanly; (b) uploaded bootstrap file
  mounted as a session resource + a first-run instruction block the ensure adds to specs;
  (c) documented-manual (library renders the script, consumer wires it) as the floor.
  Success criteria: a cloud session on an ensured `runtimes: elixir` environment runs
  `elixir --version` successfully via the built-in bash tool, without per-consumer prompt
  engineering. The spike's finding is folded back into this spec before the MIM-71 tasks
  execute.
- Self-hosted realization: contract only in 0.4 (spec records expected versions for the
  pre-baked image; drift detection = version mismatch reported by a future worker — see
  the self-hosted-sandboxes project). No live leg.
- Per-session cold-install cost on cloud is documented honestly (~15s+).

## §4 Errors and safety

- Store: `get` errors surface as misses with a warning (a broken cache must not block
  provisioning); `put`/`delete` failures log + proceed (see §1).
- `ensure_environment` provider errors pass through untouched; recovery-by-name treats
  archived environments as absent.
- `prune_environments` refuses without `keep:`; skips tagged; reports everything archived;
  a partial failure mid-prune returns `{:error, {:partial, archived_so_far, failed_on}}`.
- `resolve` on an unknown tag is `{:error, :unknown_tag}`, never a fallback to "latest".

## §5 Testing & live proof

- **Store contract tests:** one shared test module exercising the behaviour contract,
  run against BOTH `Store.ETS` and `Store.File` (tmp dir); File additionally covers
  atomicity (no partial JSON after a crash simulation), corrupt-file recovery, and the
  logged warning.
- **ensure_environment:** injected client fns (create/list) per the provider-test
  conventions; hash-distinction (specs differing only in `runtimes` produce different
  names); empty-store recovery-by-name; archived-envs-ignored.
- **Tags/prune:** pure-logic tests over `Store.File`; prune safety matrix (tagged kept,
  `keep:` required, partial-failure shape).
- **Live canary (discipline change per the model):** the CMA legs migrate to a pinned,
  reused image — first run builds, subsequent runs must HIT (assert no create call via
  telemetry or handle equality); sessions remain the only churn. New legs: ensure → tag →
  resolve → session-on-resolved-image round-trip; prune leg that GCs superseded canary
  generations (and cleans the envs past runs leaked). MIM-71 leg after the spike: ensured
  `runtimes: elixir` image + `elixir --version` via bash tool.
- QA-CHECKPOINTs A/B/C close the three PRs (Store; environments-as-images; runtimes),
  per the 0.3.0 pattern, gates including `mix credo --strict`.

## Out of scope

- `ensure_stack` (unified agent+env+tools apply) — explicitly deferred at issue-filing.
- Agent-side image unification (recorded as foreshadowing; the harness already conforms).
- DB-backed stores; concurrent-writer file stores.
- The provisioning MCP server (MIM-73, parked) and the self-hosted EnvironmentWorker
  (MIM-72, own project).
- EFS/S3-mount realization of runtimes; any Bedrock-side changes.

## Spike Verdict (Task 7, 2026-07-03 — folded back)

Four live probe rounds on `probe/runtime-spike` (temporary branch, never merged) settled §3's open question:

**Sandbox facts.** CMA cloud environments run Ubuntu 24.04 x86_64 as root (working sudo, apt-get present), 4 cores / 16 GB / ~30 GB free, network open (unrestricted env) to `mise.jdx.dev` and `repo.hex.pm`. No Erlang/Elixir preinstalled. There is NO server-side build phase — runtimes must be realized per-session by the agent itself.

**Mechanism verdict: prompt/script-delivered mise bootstrap — PROVEN (~11s end-to-end).** mise installs via its official installer in seconds; mise ships PRECOMPILED Erlang for ubuntu-24.04 (`erlang@29.0.2` in 5.4s — no kerl compile), elixir in 1.4s; `elixir --version` -> "Elixir 1.20.2 (compiled with Erlang/OTP 29)". The apt fallback is rejected: Ubuntu 24.04 ships OTP 25 (too old).

**Load-bearing details for the realization (Task 8):**
- The bootstrap script must PREPEND the mise installer (`curl -fsSL https://mise.jdx.dev/install.sh | sh`) and `export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"` — the Task-6 template assumed mise present.
- `mise use --global erlang@...` BEFORE elixir is load-bearing: bare `mise install elixir@...` fails exit-127 when erl is not on PATH (round-3 failure).
- PATH + locale must persist to `~/.bashrc` so the agent's SUBSEQUENT bash calls inherit them; the C.UTF-8 exports fix a real latin1 warning observed live.
- Realization shape (mechanism (c) enriched): `ensure_environment` returns `bootstrap: %{script: ..., instructions: ...}` in the handle when the spec declares runtimes; `Runtimes.system_prompt_block/1` renders the instruction text consumers put in the agent's system prompt. The library cannot run the bootstrap itself — sessions execute it via the agent's bash on first need.
