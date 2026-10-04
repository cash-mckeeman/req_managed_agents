# req_managed_agents_host

Durable single-node session host for [`req_managed_agents`](https://hex.pm/packages/req_managed_agents).

Turns RMA's per-call `ReqManagedAgents.Session` into a supervised, crash-survivable,
idle-detachable hosted session keyed by a caller-supplied external id. One public
function — `ReqManagedAgents.Host.send_message/3` — finds, starts, or reattaches the
right session, runs it to a terminal, and returns the RMA `SessionResult`, with the
session's upstream identity durably persisted so a BEAM restart resumes the conversation.

## Installation

```elixir
def deps do
  [
    {:req_managed_agents_host, "~> 0.3.0"}
  ]
end
```

## Quickstart

Every call needs a `:provider` (a `ReqManagedAgents.Provider`), a `:handler` (a
`ReqManagedAgents.Handler`), and a `:store` — a `{module, opts}` pair naming a
`ReqManagedAgents.Host.Store` implementation.

### In-memory (ETS)

Fastest option; the locator is gone if the owning process stops. Good for a single
long-lived node where losing in-flight session pointers on a crash is acceptable.

```elixir
{:ok, _pid} = ReqManagedAgents.Host.Store.ETS.start_link(name: :sessions)
store = {ReqManagedAgents.Host.Store.ETS, name: :sessions}

opts = [provider: MyProvider, handler: MyHandler, store: store]

{:ok, %ReqManagedAgents.SessionResult{text: text}} =
  ReqManagedAgents.Host.send_message("customer-42", "hello", opts)

# same external id later — even after the SessionServer idle-detached or crashed —
# reattaches the same upstream session instead of minting a new one
{:ok, _result} = ReqManagedAgents.Host.send_message("customer-42", "what's next?", opts)
```

### File-backed (DETS)

Use this when the locator itself must survive a full BEAM restart, not just a process
crash — e.g. a deploy or a node bounce. The upstream session id is written to disk on
every turn, so re-opening the same file after a restart reattaches exactly where the
conversation left off.

```elixir
{:ok, _pid} =
  ReqManagedAgents.Host.Store.DETS.start_link(name: :sessions, file: "/var/data/sessions.dets")

store = {ReqManagedAgents.Host.Store.DETS, name: :sessions, file: "/var/data/sessions.dets"}

opts = [provider: MyProvider, handler: MyHandler, store: store]

{:ok, _result} = ReqManagedAgents.Host.send_message("customer-42", "hello", opts)

# ...BEAM restarts; the same store is reopened from the same file on boot...

{:ok, _result} = ReqManagedAgents.Host.send_message("customer-42", "still there?", opts)
```

### Idle-detach

Sessions idle-detach after `idle_timeout_ms` (default 300_000ms / 5 minutes) of inactivity —
the `SessionServer` stops, but the `Locator` row (and thus the upstream session id) survives,
so the next `send_message/3` for the same external id starts a fresh server and reattaches:

```elixir
opts = [provider: MyProvider, handler: MyHandler, store: store, idle_timeout_ms: 60_000]
```

## Durability model

- **Live handle vs. durable state.** A `SessionServer` is a reattachable *live handle*, not
  the durable record — the `Locator` (backed by your chosen `Store`) is. The server's child
  spec is `restart: :temporary`: an idle-detach or a crash both simply end the process, and
  neither is auto-restarted by the `SessionSupervisor` — the next `send_message/3` starts a
  fresh one and reattaches through the `Locator`.
- **Crash isolation.** Each external id's session runs under its own `DynamicSupervisor`
  child; one session crashing never affects another.
- **`Store.ETS` vs. `Store.DETS`.** Pick `ETS` for process-crash isolation only; pick `DETS`
  when the locator must also survive a BEAM/node restart.
- **Local provider continuity.** Server-held providers (Claude Managed Agents, AgentCore) keep
  the conversation upstream — the `Locator`'s session pointer alone is enough to reattach.
  Client-held providers (e.g. `req_managed_agents`'s `Providers.Local`) hold the conversation
  in the caller's process instead, so the pointer alone isn't enough: on every successful turn,
  the provider's emitted transcript (`SessionResult.transcript`) is stored under a sibling
  `{:transcript, external_id}` key in your chosen `Store`, and re-seeded as `history:` the next
  time that external id runs — so a Local conversation survives a crash, an idle-detach, or a
  full BEAM restart exactly like the session pointer does. Providers that never emit a
  transcript are unaffected: nothing is stored, and no `history:` opt is added.

## License

Apache-2.0. See [LICENSE](LICENSE).
