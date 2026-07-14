# req_managed_agents

A multi-provider client for running agentic tool-use sessions on Anthropic Claude
Managed Agents (CMA), AWS Bedrock AgentCore, and a local in-process loop — all
behind one `Session` / `Provider` contract. Published to Hex; **public repo**.

## Project Structure

`lib/req_managed_agents/`:

- **`session.ex`** — the turn loop (backend-held on CMA/AgentCore, in-process on Local); the public entry (`run/2`, `start_link/1`, `message/2`).
- **`client.ex`** — the Anthropic HTTP client (Req-based); `handler.ex` — the tool-callback behaviour consumers implement.
- **`provider.ex`** + **`providers/`** — the `Provider` behaviour and its three impls: `claude_managed_agents`, `bedrock_agent_core`, `local`.
- **`provisioner/`** — content-addressed `ensure`/reconcile for environments (agents on the 0.7 roadmap); the `Store` behaviour (ETS default, File for cross-process reuse).
- **`agent_core/`** — AWS SigV4 signing + Converse wire shapes for AgentCore.
- **`open_telemetry/`** — pure `gen_ai.*` attribute mappers (no OTel SDK dependency).
- **Vocabulary structs** — `ToolUse`, `ToolResult`, `Usage`, `Outcome`, `SessionInfo`, `TurnResult`.

Tests mirror this layout under `test/`.

## Configuration

All config/env access goes through **`ReqManagedAgents.Config`** — don't call
`System.get_env` / `System.fetch_env!` / `Application.get_env` directly in `lib/`.
(One deliberate exception: `SigV4.from_env`'s `AWS_REGION` → `AWS_DEFAULT_REGION`
two-env fallback, which a single `Config.resolve` can't express.)
Resolution ladder, every key:

```
opts[key]  →  Application.get_env(:req_managed_agents, key)  →  System.get_env("VAR")  →  default
```

`Config.resolve/4` returns the first hit; `Config.resolve!/3` raises a clear
"set opt / app config / env VAR" message when a required value is missing at
every layer. Add a setting = one `Config.resolve` call + a row in the README
"Configuration" table. `config/config.exs` is an empty stub by design — the
resolver reads `Application` env for whenever a host app chooses to set it.

## Struct Discipline

The vocabulary structs are the currency of the loop. Reference them **by name** —
never as bare maps, never through `Access`:

- **Pattern-match at the function head:** `def result_of(%ToolResult{} = r)`, not `def result_of(%{is_error: e})`. This annotates the type and catches shape drift.
- **Never bracket-access a value that may be a struct.** `usage[:input_tokens]` and `usage["input_tokens"]` **raise** on a struct — structs don't implement `Access`. Use `Map.get(usage, :input_tokens)` or pattern-match. This footgun has bitten the telemetry mapper and the turn guard; it is the single most common defect class here.
- **Shape-gate untrusted input through a coercing `new/1`** — see `Outcome.new/1`: accepts a map *or* an existing struct, returns `{:ok, struct} | {:error, reason}`, and is the one place a given struct's invariants are enforced.

## Content-Addressed Provisioning

Managed resources are content-addressed, Docker-tag style:
`Provisioner.hash/1` over the spec → 8-hex digest → provider name `<base>_<digest8>`.

- **`ensure_*/3` is provision-if-absent:** check `Store` → create → double-key the handle (`provision:` + `digest:<base>:`). A create `409` means "this exact spec already exists" → recover-by-name (version-correct even with an empty store).
- **Handle** is a small map (`%{..._id:, name:, digest:}`) — nothing else persisted.
- **`tag` / `resolve` / `prune`** give movable pointers + explicit GC (`prune` requires `keep:`, never touches tagged digests).
- **`Store`** is a 4-callback behaviour; a broken store must **never block provisioning** — `store_get`/`store_put` rescue to miss / no-op-with-handle (loud but safe).

## Providers

One `Provider` behaviour, three impls. `mode/0` distinguishes how a turn's events
are *acquired*: `:streaming` (CMA — pushed over an SSE subscription) vs
`:request_response` (AgentCore, Local — pulled by a call). Local **is** the loop,
in-process: a turn is `chat_fun.(request) -> response`.

- Keep provider-specific wire shaping **inside the provider**; the `Session` loop stays provider-agnostic.
- Every network call takes an injectable seam (`create_fun` / `list_fun` / `get_fun` / `chat_fun`) so the default test suite never hits the network.

## Testing

- `async: true`; providers exercised through their seams with `Req.Test` stubs — no live calls in the default run.
- Live smoke tests sit behind a **positive** env guard (present-credentials condition) and are excluded by default; run them explicitly when creds are set.
- `mix test` is the gate. New public structs get `@enforce_keys` + a fully-typed `@type t`; new public functions get `@spec` + `@doc`.

## Code Style

- Do not put 2 or more pipes on one line:

✅
```elixir
arg
|> step_one()
|> step_two()
```
❌ `arg |> step_one() |> step_two()`

- Comments record a non-obvious, site-specific **why** — a hidden constraint, a subtle invariant. Don't restate what the code does, don't re-explain conventions that live here, and never cite a doc path or tracker id from code.
- Don't narrate transient state in comments (rollout phase, "not wired yet", what another module currently does) — it rots silently. That belongs in the PR description.

## Public-Repo Hygiene

This package is public on Hex. Internal tracker ids (issue keys like `ABC-123`,
internal phase tags) **never** appear in code, comments, moduledocs, test names,
README, CHANGELOG, or commit messages — the only permitted reference is a PR
**body** `Closes <KEY>` trailer. Keep AWS account numbers, ARNs, and internal
infra names out of source and tests — use placeholders (`role`, `arn:new`,
`us-east-1`).

## Version Control & Release

Local dev uses **jj** (see the global CLAUDE.md). Releases are **tag-triggered and
immutable**: pushing a `v<version>` tag runs CI `mix hex.publish` — the tagged tree
publishes to Hex immediately and cannot be recalled. Only tag when `@version` in
`mix.exs` matches the tree and the tree is exactly what should be public. Bump
`@version` + CHANGELOG in the release commit; tag **after** merge to `main`.

**Close what you shipped.** For every GitHub issue a change resolves, put
`Closes #<n>` (or `Fixes #<n>`) in the **PR body** so GitHub auto-closes it on
merge. A bare `(#<n>)` reference — e.g. the `(#66)` attribution style used in the
CHANGELOG — is attribution only and does **not** auto-close; those issues sit open
until closed by hand. At release, confirm no issue the release resolved is still
open. (This is GitHub-issue closing; the Linear `Closes <KEY>`-in-PR-body rule
under Public-Repo Hygiene is separate — never put a Linear id in a PR title.)

## Code Quality

```bash
mix format --check-formatted && mix credo --strict && mix test
```
