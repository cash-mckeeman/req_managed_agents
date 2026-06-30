# Provider/Session Abstraction — Design Spec (v2, corrected)

**Date:** 2026-06-29
**Status:** Draft (design)
**Supersedes:** `2026-06-29-provider-streaming-abstraction-design.md` — see "What we got wrong."
**Related:** MIM-43 (provider extraction endgame)

## What we got wrong (and what this corrects)

The first attempt produced a `Provider` behaviour that extracted three *leaf helpers*
(`decode`, `normalize`, `resume`) but **left three provider-coupled drivers in place**:

| Driver | Provider | Invocation |
|---|---|---|
| `RunToCompletion` | Claude Managed Agents | streaming, synchronous |
| `Session` | Claude Managed Agents | streaming, live GenServer |
| `AgentCore.invoke_to_completion` | Bedrock AgentCore | request/response |

Each driver still contained its own copy of the orchestration loop, and the behaviour
did **not** own the thing that actually differs between providers — **invocation**
(transport + session model). So it was not a Behaviour/Impl abstraction; it was three
loops sharing a normalizer. The normalized `turn_outcome` was internal scratch for loops
that were never unified, which is why fields like `server_tool_uses`/`text` ended up
consumed by nothing.

**The correction:** the `Provider` behaviour owns invocation end-to-end, and **one**
`Session` abstraction runs the loop against any provider. The provider-coupled drivers
collapse into it.

## The core insight: two transport modes

Every agent backend invokes in exactly one of two modes:

- **`:streaming`** (push) — the server holds a connection open and pushes events; the
  client posts inputs out-of-band; a turn ends on a marker event. *Claude Managed Agents:*
  `GET /v1/sessions/{id}/events/stream` (SSE) pushes events; `POST /v1/sessions/{id}/events`
  drives it; a turn ends on `session.status_idle`.
- **`:request_response`** (pull) — the client calls, the server answers the whole turn;
  the client resumes by calling again with the conversation **delta**. *Bedrock AgentCore:*
  `AgentCore.Client.invoke_harness/2` POSTs `InvokeHarness` and returns the full decoded
  EventStream for one turn; resume re-POSTs the assistant `toolUse` + user `toolResult`
  delta (the harness does not persist the uncommitted tool-use turn — "the 2-event delta dance").

These are the only two modes — a backend either pushes to you or answers you. (A backend
that offers both, e.g. OpenAI Assistants, just means you pick one mode for it. True
status-polling is a pull variant handled *inside* a `:request_response` provider's call.)

The loop is identical across modes; only *how a turn's events are obtained* and *how a turn
is resumed* differ — and both differences live entirely in the provider.

## The `Provider` behaviour

A provider owns its mode, its connection/session lifecycle, how it sends input and obtains
a turn's events, how it resumes, and how it normalizes. `conn` and `input` are
provider-private opaque terms the `Session` never inspects.

```elixir
defmodule ReqManagedAgents.Provider do
  @type conn :: term()          # provider-private connection / session handle
  @type input :: term()         # provider-private "what to send to drive the next turn"
  @type event :: %{required(String.t()) => term()}

  @callback mode() :: :streaming | :request_response

  @doc """
  Establish the provider connection/session and return an opaque `conn`.
  - :streaming    — create the server session + open the event stream, delivering events to
                    `subscriber` (the Session process). Returns once attached.
  - :request_response — build the signed client + session id (no stream).
  """
  @callback open(opts :: keyword(), subscriber :: pid()) :: {:ok, conn()} | {:error, term()}

  @doc "The first input that kicks off the conversation (e.g. the user's initial message)."
  @callback kickoff_input(opts :: keyword()) :: input()

  @doc "Build the input that resumes the loop after local tools ran (the mode's resume contract)."
  @callback resume_input(custom_tool_uses :: [map()], results :: [map()]) :: input()

  @doc "Fold a turn's raw events into the canonical turn outcome (carries the raw events verbatim)."
  @callback normalize([event()]) :: turn_outcome()

  # ── :request_response mode only ──────────────────────────────────────────────
  @doc "Run one turn synchronously: send `input`, return the turn's raw events."
  @callback poll_turn(conn(), input()) :: {:ok, [event()], conn()} | {:error, term()}

  # ── :streaming mode only ─────────────────────────────────────────────────────
  @doc "Post `input` to the open stream. Events arrive asynchronously at the subscriber."
  @callback push_input(conn(), input()) :: :ok | {:error, term()}

  @doc "Streaming turn boundary: does this event close a turn (so accumulated events form one)?"
  @callback turn_boundary?(event()) :: boolean()

  @optional_callbacks poll_turn: 2, push_input: 2, turn_boundary?: 1
end
```

### How each provider implements it

**`Providers.ClaudeManagedAgents`** (`mode() == :streaming`), grounded in `Client` + `Stream`:
- `open/2` — `Client.create_session/2`, then `Stream.stream/4` in a Task delivering
  `{:managed_agents, ref, …}` to `subscriber`; await `:connected`. `conn` = `%{client, session_id, ref, stream_task}`.
- `kickoff_input(opts)` — `[Event.user_message(opts[:prompt] || "Begin.")]`.
- `push_input(conn, events)` — `Client.send_events(conn.client, conn.session_id, events)`.
- `turn_boundary?` — `true` for `session.status_idle` / `session.status_terminated` / `session.error`.
- `resume_input(_uses, results)` — `Enum.map(results, &Event.custom_tool_result/…)` (no echo).
- `normalize/1` — the existing fold (terminal, `custom_tool_uses` via `event_ids`,
  `server_tool_uses` from `agent.tool_use`, `text` from `agent.message`, raw `events`).

**`Providers.BedrockAgentCore`** (`mode() == :request_response`), grounded in `AgentCore.Client`:
- `open/2` — build/keep the SigV4 client + `runtime_session_id`. `conn` = `%{client, harness_arn, sid, model}`. (`subscriber` unused.)
- `kickoff_input(opts)` — `[%{"role" => "user", "content" => [%{"text" => opts[:prompt] || "Begin."}]}]`.
- `poll_turn(conn, messages)` — `AgentCore.Client.invoke_harness(conn.client, %{harness_arn, runtime_session_id, messages, …})` → `{:ok, events, conn}`; owns its truncation-retry and `__stream_error__` surfacing (today's `invoke_turn/3` logic).
- `resume_input(uses, results)` — `Converse.resume_messages(uses, results)` (the assistant `toolUse` + user `toolResult` delta).
- `normalize/1` — the existing Converse-based fold (+ raw `events`).

## The unified `Session`

One module replaces all three drivers. It is a GenServer (so the same code serves the
synchronous run, the live-streaming UX, follow-up messages, and — for streaming — reconnect).
It runs the **same loop** regardless of mode; mode only changes how it *acquires a turn*.

### Public API

```elixir
# Synchronous run-to-completion (replaces RunToCompletion + invoke_to_completion):
@spec run(module(), keyword()) :: {:ok, result()} | {:error, term()}
def run(provider, opts)        # blocks; returns %{terminal, stop_reason, events}

# Live / long-lived (replaces today's Session GenServer):
def start_link(provider, opts) # opts[:notify] gets {:managed_agents_session, terminal};
                               # opts[:handler] runs tools; handle_event/2 sees every raw event
def message(pid, text)         # follow-up user message
```

`run/1` is `start_link` + drive-to-terminal + return + stop, but exposed as a blocking call.

### The shared loop (mode-dispatched only at "acquire a turn")

```elixir
# Drive one turn → run tools → resume → repeat, until a terminal.
defp loop(state, input) do
  with {:ok, turn_events, state} <- acquire_turn(state, input) do
    outcome = state.provider.normalize(turn_events)
    forward_raw(state, turn_events)                       # live subscribers / handle_event
    case outcome.terminal do
      :requires_action ->
        results = run_tools(outcome.custom_tool_uses, state)   # Tools.run/6, provider-agnostic
        loop(state, state.provider.resume_input(outcome.custom_tool_uses, results))
      terminal ->
        finish(state, terminal, outcome.stop_reason)
    end
  end
end

# The ONLY mode-specific step:
defp acquire_turn(%{mode: :request_response} = s, input) do
  with {:ok, events, conn} <- s.provider.poll_turn(s.conn, input), do: {:ok, events, %{s | conn: conn}}
end

defp acquire_turn(%{mode: :streaming} = s, input) do
  :ok = s.provider.push_input(s.conn, input)
  collect_until_boundary(s, [])     # receive {:managed_agents, ref, {:event, ev}} until turn_boundary?(ev)
end
```

- **Tool execution, terminal classification, timeout, max-turns, telemetry, and raw-event
  forwarding are all shared** (provider-agnostic), in the `Session`.
- **Provider-specific concerns are all inside the provider:** transport, session lifecycle,
  truncation-retry (request/response), reconnect-with-consolidation (streaming), the resume
  contract. Streaming reconnect stays a streaming-provider concern surfaced through `open`.

### Raw events (the preserved principle)

`turn_outcome` still carries the raw `events` verbatim, and the loop forwards every raw event
to live subscribers / `handle_event/2`. Normalization remains additive, never lossy — a
consumer can always read the provider's documented wire shapes.

## Canonical `turn_outcome` (unchanged from v1)

```elixir
%{
  terminal: :end_turn | :requires_action | :terminated,
  stop_reason: String.t() | nil,                 # raw provider string
  custom_tool_uses: [%{id, name, input}],         # client-side / return-of-control (actionable)
  server_tool_uses: [%{id, name, input}],         # provider-executed (observe-only)
  text: String.t(),                               # assistant text
  events: [event()]                               # raw provider events, verbatim
}
```

## Migration

The v1 work is **not** discarded — `normalize/1`, the canonical vocabulary, the providers,
and the raw-event passthrough all carry forward into the fuller behaviour. The new work is
adding the *invocation* callbacks and the unified `Session`, then deleting the three drivers.

1. **Extend `Provider`** with `mode/0`, `open/2`, `kickoff_input/1`, `resume_input/2`,
   `poll_turn/2` (request_response), `push_input/2` + `turn_boundary?/1` (streaming).
   Keep `normalize/1`. (`decode/1` becomes internal to the stream/poll path.)
2. **Grow the two providers** into full implementations (move `Client.invoke_harness` use,
   `Stream`/`Client.send_events` use, `Converse.resume_messages`/`Event.custom_tool_result`
   into the provider callbacks). The existing `AgentCore.Client`, `Stream`, `Client`,
   `Converse`, `EventStream`, `SSE` modules stay — providers compose them.
3. **Build the unified `Session`** (GenServer) with the shared loop + mode-dispatched
   `acquire_turn`, `run/2`, `start_link/2`, `message/2`.
4. **Collapse the drivers:** reimplement `RunToCompletion.run/1` and
   `AgentCore.invoke_to_completion/1` as thin shims over `Session.run/2` (or delete them and
   update call sites); fold today's `Session` into the unified one. Preserve public result
   shapes and the `:notify` / `handle_event/2` contracts.
5. **Tests:** the existing provider/normalize/conformance tests carry over. Add: a
   shared `Session` loop test run against BOTH a fake `:streaming` and a fake
   `:request_response` provider (proving the loop is mode-agnostic); migrate the
   `run_to_completion`/`session`/`agent_core` driver tests onto `Session`.

## Intentional behavior changes vs the old drivers

The collapse preserves the public result shape and resilience properties, but a few behaviors
change deliberately (all surfaced by the whole-branch review and accepted, not accidental):

- **`stop_reason` is now the canonical string on the Claude path.** The old Claude drivers
  returned the raw `stop_reason` **map** (`%{"type" => "end_turn", …}`); the unified result
  returns the string `"end_turn"`, consistent with the AgentCore path. The full raw map is
  always available in `turn_outcome.events` (the raw-preservation principle), so nothing is lost.
- **`notify` terminal taxonomy is the canonical three atoms.** A streaming session that used to
  notify `:error`/`:retries_exhausted` now notifies `:terminated`; the raw provider reason is in
  the result's `stop_reason` / `events`.
- **Telemetry is unified under `[:req_managed_agents, :session, …]`.** The old per-driver
  `[:req_managed_agents, :agent_core, :terminal | :tool_uses]` events are gone; both providers now
  emit `[:session, :terminal]` and a per-turn `[:session, :tool_uses]` (carrying the MIM-52
  duplicate-id sentinel). The OTel bridge already maps `:session, :terminal`.
- **`run_to_completion` default timeout is 600s** (was 120s), matching the unified default.

## Non-goals

- New providers (OpenAI, Google) — the behaviour is *designed to admit* them (each picks a
  mode), but none are built here.
- Changing the wire clients (`AgentCore.Client`, `Client`, `Stream`, `EventStream`, `SSE`) —
  they are composed, not rewritten.

## Open questions for plan-time

- `run/2` returning `{terminal, stop_reason, events}` vs the full `turn_outcome` — decide once
  the unified `Session` exists (the raw `events` are the complete per-run record; normalized
  fields are per-turn).
- Whether `Session.run/2` spins the GenServer or runs the loop inline for `:request_response`
  (no stream to own) — an optimization, not a contract.
