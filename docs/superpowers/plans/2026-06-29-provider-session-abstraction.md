# Provider/Session Abstraction Implementation Plan (v2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A real provider abstraction: a `Provider` behaviour that owns invocation (in one of two transport modes — `:streaming` / `:request_response`) and **one** unified `Session` that runs the same loop against any provider, replacing the three provider-coupled drivers.

**Architecture:** `Provider` behaviour = `mode/0`, `open/2`, `kickoff_input/1`, `user_input/1`, `resume_input/2`, `normalize/1`, plus mode-specific `poll_turn/2` (request_response) and `push_input/2` + `turn_boundary?/1` (streaming). The `Session` GenServer runs one reactive loop — *acquire a turn → normalize → run tools → resume → repeat* — dispatching on mode only at "acquire a turn." `Session.run/2` is the synchronous wrapper; `start_link/2` + `message/2` is the live UX.

**Tech Stack:** Elixir, GenServer, ExUnit. Composes existing wire modules (`AgentCore.Client`, `Client`, `Stream`, `Converse`, `EventStream`, `SSE`, `Event`, `Tools`) unchanged. No new deps.

**Spec:** `docs/superpowers/specs/2026-06-29-provider-session-abstraction-design.md`

## Global Constraints

- Two transport modes only: `:streaming` (push) and `:request_response` (pull). The provider declares its mode.
- The `Session` loop is provider-agnostic and mode-agnostic except `acquire_turn`. Tool execution, terminal/timeout/max-turns, telemetry, raw-event forwarding are all shared.
- Canonical `turn_outcome` = `%{terminal, stop_reason, custom_tool_uses, server_tool_uses, text, events}`. `events` is the raw provider events, preserved verbatim (normalization is additive, never lossy).
- Terminal taxonomy: `:end_turn | :requires_action | :terminated`.
- Wire clients (`AgentCore.Client`, `Client`, `Stream`, `Converse`, `EventStream`, `SSE`, `Event`, `Tools`) are **composed, not rewritten**.
- Public result of a completed run: `{:ok, %{terminal, stop_reason, events}}` (matches today's drivers).
- `Session`'s live contract: `opts[:notify]` receives `{:managed_agents_session, terminal}`; a module `:handler` with `handle_event/2` receives every raw event.

## Reuse note (carried forward from the abandoned v1 branch)

The v1 branch (`.claude/worktrees/provider-abstraction`) has correct, reviewed modules to **copy as starting material**, then extend:
- `lib/req_managed_agents/provider.ex` — behaviour + canonical types + `result_of/2`.
- `lib/req_managed_agents/providers/bedrock_agent_core.ex` — `normalize/1`, `terminal/1`.
- `lib/req_managed_agents/providers/claude_managed_agents.ex` — `normalize/1`, `terminal/1`, `assistant_text/1`, `server_tool_uses/1`, `latest_status/1`.
- Their test files + `test/req_managed_agents/provider_conformance_test.exs` + `test/support/sse_fixtures.ex` (`agent_message/2`).
Copy with `cp` from that worktree; do NOT re-derive. Each task says what to copy and what to add.

---

### Task 1: `Provider` behaviour (add the invocation surface)

**Files:**
- Create (copy + extend): `lib/req_managed_agents/provider.ex`
- Test: `test/req_managed_agents/provider_test.exs` (copy v1; it still passes)

- [ ] **Step 1: Copy the v1 behaviour + its test**
```bash
cp ../provider-abstraction/lib/req_managed_agents/provider.ex lib/req_managed_agents/provider.ex
cp ../provider-abstraction/test/req_managed_agents/provider_test.exs test/req_managed_agents/provider_test.exs
```

- [ ] **Step 2: Add the invocation callbacks + opaque types** to `provider.ex` (after the existing `@callback normalize/1`, keep `result_of/2`):
```elixir
  @typedoc "Provider-private connection / session handle."
  @type conn :: term()
  @typedoc "Provider-private input that drives the next turn."
  @type input :: term()

  @callback mode() :: :streaming | :request_response

  @doc "Establish the connection/session; for :streaming, open the event stream to `subscriber`."
  @callback open(opts :: keyword(), subscriber :: pid()) :: {:ok, conn()} | {:error, term()}

  @doc "Input that kicks off the conversation (the initial user message)."
  @callback kickoff_input(opts :: keyword()) :: input()

  @doc "Input for a follow-up user message into a running session."
  @callback user_input(text :: String.t()) :: input()

  @doc "Input that resumes the loop after local tools ran (the mode's resume contract)."
  @callback resume_input(custom_tool_uses :: [map()], results :: [map()]) :: input()

  # :request_response only — run one turn synchronously.
  @callback poll_turn(conn(), input()) :: {:ok, [event()], conn()} | {:error, term()}

  # :streaming only — post input (events arrive async at the subscriber) + turn-boundary test.
  @callback push_input(conn(), input()) :: :ok | {:error, term()}
  @callback turn_boundary?(event()) :: boolean()

  @optional_callbacks poll_turn: 2, push_input: 2, turn_boundary?: 1
```

- [ ] **Step 3: Run** `mix test test/req_managed_agents/provider_test.exs` → PASS. Then `mix compile --warnings-as-errors`.

- [ ] **Step 4: Commit** (`jj describe -m "feat(provider): behaviour owns invocation (mode/open/poll_turn/push_input)"; jj new`)

---

### Task 2: `Providers.BedrockAgentCore` — full `:request_response` provider

**Files:**
- Create (copy + extend): `lib/req_managed_agents/providers/bedrock_agent_core.ex`
- Test: `test/req_managed_agents/providers/bedrock_agent_core_test.exs` (copy v1 + add invocation tests)

**Interfaces consumed:** `AgentCore.Client.invoke_harness/2`, `AgentCore.Converse.resume_messages/2`, existing `normalize/1`/`terminal/1` (copied).

- [ ] **Step 1: Copy v1 provider + test** (`cp` both files from the v1 worktree).

- [ ] **Step 2: Add the invocation callbacks** to `bedrock_agent_core.ex` (port the retry/`__stream_error__` logic from v1 `agent_core.ex:invoke_turn/3`):
```elixir
  @behaviour ReqManagedAgents.Provider
  @impl true
  def mode, do: :request_response

  @impl true
  def open(opts, _subscriber) do
    client = opts[:client] || ReqManagedAgents.AgentCore.Client.new()
    {:ok,
     %{client: client, harness_arn: Keyword.fetch!(opts, :harness_arn),
       sid: Keyword.fetch!(opts, :runtime_session_id), model: opts[:model],
       retries: opts[:invoke_retries] || 2, meta: opts[:telemetry_metadata] || %{}}}
  end

  @impl true
  def kickoff_input(opts),
    do: [%{"role" => "user", "content" => [%{"text" => opts[:prompt] || "Begin."}]}]

  @impl true
  def user_input(text), do: [%{"role" => "user", "content" => [%{"text" => text}]}]

  @impl true
  def resume_input(custom_tool_uses, results) do
    wire = Enum.map(custom_tool_uses, fn %{id: id, name: name, input: input} ->
      %{"toolUseId" => id, "name" => name, "input" => input}
    end)
    ReqManagedAgents.AgentCore.Converse.resume_messages(wire, results)
  end

  @impl true
  def poll_turn(conn, messages), do: invoke(conn, messages, conn.retries)

  defp invoke(conn, messages, retries_left) do
    inv = %{harness_arn: conn.harness_arn, runtime_session_id: conn.sid, messages: messages, model: conn.model}
    case ReqManagedAgents.AgentCore.Client.invoke_harness(conn.client, inv) do
      {:ok, events} ->
        case stream_error(events) do
          {type, message} -> {:error, {:harness_stream_error, type, message}}
          nil ->
            # A truncated turn (no terminal stop_reason) is retried; else surface the turn.
            if normalize(events).stop_reason != nil or retries_left == 0,
              do: {:ok, events, conn},
              else: invoke(conn, messages, retries_left - 1)
        end
      {:error, _} when retries_left > 0 -> invoke(conn, messages, retries_left - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  # (copy stream_error/1 + stream_error_message/1 from v1 agent_core.ex)
```

- [ ] **Step 3: Add tests** to `bedrock_agent_core_test.exs`: `mode/0 == :request_response`; `kickoff_input/1`; `resume_input/2` returns the 2-message delta; `poll_turn/2` with an injected `:client` (Req.Test stub or an `invoke_fun`-style seam) returns a turn's events; a `__stream_error__` frame → `{:error, {:harness_stream_error, …}}`. Keep the v1 `normalize`/MIM-52/exclusion tests.

- [ ] **Step 4: Verify** (`mix test test/req_managed_agents/providers/bedrock_agent_core_test.exs`, `mix compile --warnings-as-errors`) and **commit**.

---

### Task 3: `Providers.ClaudeManagedAgents` — full `:streaming` provider

**Files:**
- Create (copy + extend): `lib/req_managed_agents/providers/claude_managed_agents.ex`
- Test: `test/req_managed_agents/providers/claude_managed_agents_test.exs` (copy v1 + add invocation tests)

**Interfaces consumed:** `Client.create_session/2`, `Stream.stream/4`, `Client.send_events/3`, `Event.user_message/1`, `Event.custom_tool_result/3`, existing `normalize/1` (copied).

- [ ] **Step 1: Copy v1 provider + test** (and ensure `test/support/sse_fixtures.ex` has `agent_message/2` — copy if missing).

- [ ] **Step 2: Add the invocation callbacks** to `claude_managed_agents.ex` (port `open` from v1 `RunToCompletion.run/1`'s create-session + `Stream.stream` Task setup):
```elixir
  @behaviour ReqManagedAgents.Provider
  @impl true
  def mode, do: :streaming

  @impl true
  def open(opts, subscriber) do
    client = opts[:client] || ReqManagedAgents.Client.new()
    body = %{agent: Keyword.fetch!(opts, :agent_id), environment_id: Keyword.fetch!(opts, :environment_id)}
    case ReqManagedAgents.Client.create_session(client, body) do
      {:ok, %{"id" => sid}} ->
        ref = make_ref()
        {:ok, _task} = Task.start_link(fn ->
          ReqManagedAgents.Stream.stream(client, sid, subscriber, ref: ref,
            telemetry_metadata: opts[:telemetry_metadata] || %{})
        end)
        {:ok, %{client: client, session_id: sid, ref: ref}}
      {:error, reason} -> {:error, {:create_session_failed, reason}}
    end
  end

  @impl true
  def kickoff_input(opts), do: [ReqManagedAgents.Event.user_message(opts[:prompt] || "Begin.")]

  @impl true
  def user_input(text), do: [ReqManagedAgents.Event.user_message(text)]

  @impl true
  def resume_input(_custom_tool_uses, results) do
    Enum.map(results, fn r ->
      ReqManagedAgents.Event.custom_tool_result(r.tool_use_id, r.text, is_error: r.is_error)
    end)
  end

  @impl true
  def push_input(conn, events) do
    case ReqManagedAgents.Client.send_events(conn.client, conn.session_id, events) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  @impl true
  def turn_boundary?(%{"type" => "session.status_idle"}), do: true
  def turn_boundary?(%{"type" => "session.status_terminated"}), do: true
  def turn_boundary?(%{"type" => "session.error"}), do: true
  def turn_boundary?(_), do: false
```
> NOTE: confirm `Client.send_events/3`'s return shape and the stream `ref` exposure (`conn.ref` must match the `ref` the Session filters on — the Session learns it from `open`'s `conn`).

- [ ] **Step 3: Add tests**: `mode/0 == :streaming`; `turn_boundary?/1` (true for the three session events, false otherwise); `kickoff_input`/`user_input`; `resume_input/2` builds `user.custom_tool_result` events. Keep all v1 `normalize`/text/server_tool_uses/raw-preservation tests.

- [ ] **Step 4: Verify + commit.**

---

### Task 4: Unified `Session` core (the shared loop) + fake-provider tests

**Files:**
- Create: `lib/req_managed_agents/session2.ex` (temporary name; renamed to `Session` in Task 6 after the old one is removed)
- Create: `test/support/fake_providers.ex` (in-memory `:streaming` + `:request_response` providers)
- Test: `test/req_managed_agents/session_loop_test.exs`

**Interfaces:** `Provider` behaviour (Task 1), `Provider.result_of/2`, `ReqManagedAgents.Tools.run/6`.

- [ ] **Step 1: Write the fake providers** (no network — prove the loop is mode-agnostic):
  - `FakeRequestResponse`: `mode :request_response`; `open` returns a `conn` holding a scripted list of turns (each turn = `[events]`); `poll_turn(conn, input)` pops the next scripted turn; `resume_input`/`kickoff_input`/`user_input` record inputs; `normalize` delegates to a simple fold or a stub returning a provided `turn_outcome`.
  - `FakeStreaming`: `mode :streaming`; `open` spawns nothing but stores `subscriber`; `push_input` sends the next scripted turn's events (one `{:managed_agents, ref, {:event, ev}}` per event, ending with a `status_idle`) to the subscriber; `turn_boundary?` true on `status_idle`.
  Both share a tiny `normalize` that reads `event_ids`/tool events so the loop's branching is exercised for real.

- [ ] **Step 2: Write the failing loop test** — drive each fake provider through: a `requires_action` turn (tools run, resume sent) then an `end_turn`, asserting the result `%{terminal: :end_turn, events: …}`, that the handler ran with the right tool args, and that `resume_input` received the tool results. One test body, run against BOTH fakes (proving mode-agnosticism).

- [ ] **Step 3: Implement `Session` core.** Full code:
```elixir
defmodule ReqManagedAgents.Session2 do
  use GenServer
  alias ReqManagedAgents.{Provider, Tools}

  @spec run(module(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(provider, opts) do
    {:ok, pid} = GenServer.start_link(__MODULE__, {provider, Keyword.put(opts, :caller, self())})
    timeout = opts[:timeout] || 600_000
    receive do
      {:session_result, ^pid, result} -> result
    after timeout -> GenServer.stop(pid, :normal); {:error, :timeout}
    end
  end

  @impl true
  def init({provider, opts}) do
    case provider.open(opts, self()) do
      {:ok, conn} ->
        state = %{provider: provider, mode: provider.mode(), conn: conn,
          handler: Keyword.fetch!(opts, :handler), context: opts[:context],
          caller: opts[:caller], notify: opts[:notify], meta: opts[:telemetry_metadata] || %{},
          events: [], turn_events: [], turns: 0, max_turns: opts[:max_turns] || 50,
          ref: Map.get(conn, :ref)}
        {:ok, state, {:continue, :kickoff}}
      {:error, reason} -> {:stop, {:open_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:kickoff, state), do: drive(state, state.provider.kickoff_input_opts(state))

  # ── acquire a turn (the ONLY mode-specific step) ──────────────────────────────
  defp drive(%{mode: :request_response} = s, input) do
    parent = self(); %{provider: p, conn: c} = s
    Task.start_link(fn -> send(parent, {:turn, p.poll_turn(c, input)}) end)
    {:noreply, s}
  end

  defp drive(%{mode: :streaming} = s, input) do
    case s.provider.push_input(s.conn, input) do
      :ok -> {:noreply, %{s | turn_events: []}}
      {:error, reason} -> stop_error(s, reason)
    end
  end

  @impl true
  def handle_info({:turn, {:ok, events, conn}}, s) do
    Enum.each(events, &forward_raw(s, &1))
    handle_turn(%{s | conn: conn}, events)
  end

  def handle_info({:turn, {:error, reason}}, s), do: stop_error(s, reason)

  def handle_info({:managed_agents, ref, {:event, ev}}, %{ref: ref} = s) do
    forward_raw(s, ev)
    s = %{s | turn_events: s.turn_events ++ [ev]}
    if s.provider.turn_boundary?(ev), do: handle_turn(s, s.turn_events), else: {:noreply, s}
  end

  def handle_info({:managed_agents, ref, :connected}, %{ref: ref} = s), do: {:noreply, s}
  def handle_info({:managed_agents, ref, :done}, %{ref: ref} = s), do: {:noreply, s}
  def handle_info({:managed_agents, ref, {:error, reason}}, %{ref: ref} = s), do: stop_error(s, reason)
  def handle_info(_other, s), do: {:noreply, s}

  # ── shared per-turn handling ──────────────────────────────────────────────────
  defp handle_turn(s, turn_events) do
    s = %{s | events: s.events ++ turn_events, turns: s.turns + 1}
    outcome = s.provider.normalize(turn_events)

    cond do
      s.turns > s.max_turns -> stop_error(s, {:max_turns_exceeded, s.max_turns})
      outcome.terminal == :requires_action ->
        results = run_tools(outcome.custom_tool_uses, s)
        drive(s, s.provider.resume_input(outcome.custom_tool_uses, results))
      true -> finish(s, outcome.terminal, outcome.stop_reason)
    end
  end

  defp run_tools(custom_tool_uses, s) do
    Enum.map(custom_tool_uses, fn %{id: id, name: name, input: input} ->
      wire = Tools.run(s.handler, id, name, input, s.context, s.meta)
      Provider.result_of(id, wire)
    end)
  end

  defp finish(s, terminal, stop_reason) do
    :telemetry.execute([:req_managed_agents, :session, :terminal], %{}, Map.put(s.meta, :terminal, terminal))
    notify(s, terminal)
    reply(s, {:ok, %{terminal: terminal, stop_reason: stop_reason, events: s.events}})
  end

  defp stop_error(s, reason), do: reply(s, {:error, reason})

  # A synchronous run/2 caller gets the result and the GenServer stops; a live session
  # (no caller) stays alive after a non-error terminal to accept follow-up messages.
  defp reply(%{caller: caller} = s, result) when is_pid(caller) do
    send(caller, {:session_result, self(), result})
    {:stop, :normal, s}
  end
  defp reply(s, {:error, _} = _result), do: {:stop, :normal, s}
  defp reply(s, {:ok, _}), do: {:noreply, s}

  defp forward_raw(%{handler: h, context: ctx}, ev) when is_atom(h) do
    if function_exported?(h, :handle_event, 2), do: h.handle_event(ev, ctx)
    :ok
  end
  defp forward_raw(_s, _ev), do: :ok

  defp notify(%{notify: pid}, terminal) when is_pid(pid), do: send(pid, {:managed_agents_session, terminal})
  defp notify(_s, _terminal), do: :ok
end
```
> NOTE: `kickoff_input_opts(state)` is shorthand — call `state.provider.kickoff_input(opts)`; thread `opts` into state in `init` (add `opts: opts` to the state map) and call `state.provider.kickoff_input(state.opts)`.

- [ ] **Step 4: Run the loop test** against both fakes → PASS. `mix compile --warnings-as-errors`. Full suite green.

- [ ] **Step 5: Commit.**

---

### Task 5: `Session` live UX — `start_link/2`, `message/2`, notify/handle_event, reconnect

**Files:**
- Modify: `lib/req_managed_agents/session2.ex`
- Test: `test/req_managed_agents/session_live_test.exs` (Bypass-backed, mirroring today's `session_test.exs`)

- [ ] **Step 1:** Add `start_link/2` (public, no `:caller` → stays alive), `message/2` (`GenServer.cast` → `drive(state, provider.user_input(text))`), and a `child_spec/1` (restart `:transient`).
- [ ] **Step 2:** Port streaming **reconnect-with-consolidation** from the old `Session` as a **streaming-provider concern**: on `{:managed_agents, ref, {:error, _}}` the provider re-opens (via `Consolidate` + a fresh stream) and hands the Session a new `conn`/`ref`. Keep `seen`-id dedup for streaming.
- [ ] **Step 3:** Tests mirroring today's `session_test.exs` (Bypass): full `requires_action → custom_tool_result → end_turn` cycle asserting `assert_receive {:managed_agents_session, :end_turn}`; a handler `{:error, _}` posts `is_error: true`; `message/2` follow-up.
- [ ] **Step 4: Verify + commit.**

---

### Task 6: Collapse the old drivers into `Session`

**Files:**
- Rename `session2.ex` → `session.ex` (module `ReqManagedAgents.Session`) — **after** deleting the old `session.ex`.
- Delete: old `lib/req_managed_agents/run_to_completion.ex`, old `session.ex`; reduce `lib/req_managed_agents/agent_core.ex` to a shim (or delete + update call sites).
- Modify: `lib/req_managed_agents.ex` facade (`run_to_completion/1`, `invoke_to_completion/1` → `Session.run/2` shims preserving result shape) and any caller.

- [ ] **Step 1:** Grep call sites: `grep -rn "RunToCompletion\|invoke_to_completion\|ReqManagedAgents.Session\b\|AgentCore.invoke_to_completion" lib test`.
- [ ] **Step 2:** Implement shims so the public API is unchanged:
  - `ReqManagedAgents.run_to_completion(opts)` → `Session.run(Providers.ClaudeManagedAgents, opts)`.
  - `ReqManagedAgents.AgentCore.invoke_to_completion(opts)` → `Session.run(Providers.BedrockAgentCore, opts)` (or update callers directly).
- [ ] **Step 3:** Delete the old driver modules; rename `Session2` → `Session`; update references.
- [ ] **Step 4:** Migrate the old `run_to_completion_test.exs` / `session_test.exs` / `agent_core` driver tests onto the shims/`Session` (assertions unchanged where the contract is preserved; update only where behavior intentionally changed). Do NOT weaken assertions.
- [ ] **Step 5:** `mix compile --warnings-as-errors`; full suite green across seeds. **Commit.**

---

### Task 7: Cross-mode conformance + cleanup + docs

**Files:**
- Create/port: `test/req_managed_agents/provider_conformance_test.exs` (copy v1 + add the `mode`/invocation callbacks to the conformance sweep).
- Modify: module docs; the spec's "Open questions" resolved inline.

- [ ] **Step 1:** Conformance: assert each provider implements its mode's required callbacks (`poll_turn` for request_response; `push_input`+`turn_boundary?` for streaming) and the shared ones (`mode/open/kickoff_input/user_input/resume_input/normalize`).
- [ ] **Step 2:** A cross-mode `Session.run` test: the SAME scripted conversation produces the SAME result through a fake `:streaming` and a fake `:request_response` provider.
- [ ] **Step 3:** Resolve the spec's open questions in docs: `run/2` returns `{terminal, stop_reason, events}` (raw is the complete record); request_response goes through the GenServer (uniform).
- [ ] **Step 4:** Final `mix test` (default + `--seed 0`) green; `mix compile --warnings-as-errors` clean. **Commit.**

---

## Self-Review

- **Spec coverage:** behaviour invocation surface (T1), both providers full (T2/T3), unified Session loop (T4), live UX (T5), driver collapse (T6), conformance (T7). ✓
- **Mode-agnostic loop proven** by the fake-provider loop test (T4) + cross-mode run test (T7). ✓
- **Reuse, not rewrite:** normalize/vocabulary/providers copied from v1; wire clients composed unchanged. ✓
- **No placeholders:** novel code (behaviour callbacks, Session) is complete; carried-forward code is copied from named v1 files; composed modules are named with their real functions.
- **Risks:** (a) `Client.send_events/3` return shape + stream `ref` exposure — verify in T3 against the real `Client`/`Stream`. (b) request_response `poll_turn` blocking — handled by running it in a `Task` (T4). (c) reconnect semantics — ported as a streaming-provider concern (T5), tested via Bypass.

## Execution Handoff

Subagent-Driven on a **new worktree from origin/main** (the v1 branch / PR #12 is abandoned). The spec + this plan get copied into the new worktree as the first commit; the v1 worktree stays on disk only as the copy-source until Task 6 completes.
