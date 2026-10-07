# Changelog

All notable changes to `req_managed_agents_host` are documented here.

## v0.12.0

- Requires `{:req_managed_agents, "~> 0.12.0"}` (was `~> 0.11.0`).
- A `:budget` in `provider_opts` is passed to the turn that creates the session
  and dropped from reattach turns. A budget can only be set when a session is
  created, so a reattach that repeated it would fail every turn after the first.
  A budget added to the config later does not apply to sessions that already exist.
- The version now follows `req_managed_agents`' minor: both packages release each minor
  together, so 0.4 to 0.11 were skipped.
- The source moved to the `req_managed_agents_host/` directory of
  https://github.com/cash-mckeeman/req_managed_agents, and the package links point there.
- The package lists its files explicitly, so `priv/plts` no longer ships.

## v0.3.0

- Requires Elixir 1.20 or later (was 1.16), forced by `req_managed_agents`
  0.11's own floor. Projects on an older Elixir should stay on 0.2.x.
- Requires `{:req_managed_agents, "~> 0.11.0"}` (was `~> 0.10`). No API or
  behaviour change here: `req_managed_agents` 0.11's breaking changes are
  confined to AgentCore harness provisioning (see its CHANGELOG) — existing
  AgentCore harnesses need a one-time re-provision, but this package's surface
  is unaffected.
- CI tests Elixir 1.20 on OTP 28 and 29 (was Elixir 1.18 / OTP 27 and
  Elixir 1.20 / OTP 29).

## v0.2.0

- Transcript persistence: providers that emit `SessionResult.transcript`
  (req_managed_agents >= 0.10, e.g. `Providers.Local`) get it stored under a
  sibling `{:transcript, external_id}` Store key and re-injected as `history:`
  on reattach — local conversations now survive process crashes, idle-detach,
  and full BEAM restarts.
- Server-held providers (Claude Managed Agents, AgentCore) are unaffected:
  no transcript emitted, nothing stored, opts unchanged.
- Requires `{:req_managed_agents, "~> 0.10"}`.

## v0.1.0

Initial release: a durable, single-node session host over `req_managed_agents`.

### Added

- `ReqManagedAgents.Host.send_message/3` — the whole public surface. Finds, starts, or
  reattaches the live session for a caller-supplied external id, runs one turn to a terminal
  via `ReqManagedAgents.Session.run/2`, and returns the RMA `SessionResult`.
- `ReqManagedAgents.Host.Config` — validated, struct-first host configuration
  (`:provider`, `:handler`, `:store` required; optional `:agent`/`:environment` handles,
  `:idle_timeout_ms`, `:timeout_ms`, `:metadata`).
- `ReqManagedAgents.Host.Store` behaviour, with two implementations:
  - `Store.ETS` — process-local, in-memory; gone when its owner process stops.
  - `Store.DETS` — file-backed; the locator survives a full BEAM restart.
- `ReqManagedAgents.Host.Locator` (+ `Locator.Record`) — the durable
  `external_id -> upstream identity` map that backs reattach and idle-detach.
- `ReqManagedAgents.Host.SessionServer` — a per-external-id `GenServer` driving one turn at a
  time. Idle-detaches after `idle_timeout_ms`; its child spec is `restart: :temporary`, so
  both idle-detach and a crash simply end the process — the next `send_message/3` re-creates
  it and reattaches through the `Locator` rather than being auto-restarted in place.
- `ReqManagedAgents.Host.SessionSupervisor` — a `DynamicSupervisor` holding one live session
  per external id; killing one server never affects a sibling.
- An OTP application (the `mod:` entry in `mix.exs`) starts the session `Registry` and
  the `SessionSupervisor`.
