# RMA 0.4.1 — run/2 Timeout Cancels In-Flight Work Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `Session.run/2` timeout tears down the in-flight provider work client-side — the request/response poll task (Bedrock AgentCore invoke) and the streaming consumer task — so Finch closes the HTTP stream instead of leaving it running after the caller has already received `{:error, :timeout}`.

**Architecture:** `Session` (a GenServer that traps exits) currently stops via `GenServer.stop(pid, :normal)` on timeout; because the exit reason is `:normal`, the linked poll/consumer Tasks ignore the exit signal and keep running their HTTP requests. Fix: track the in-flight poll task pid in session state and add a `terminate/2` callback that kills the poll task and the stream consumer if still alive. No API change.

**Tech Stack:** Elixir ~> 1.16, ExUnit. No new deps.

**Spec:** `docs/superpowers/specs/2026-07-04-mim79-consolidation-architecture-design.md` §4 (0.4.1 row); binding detail in the position doc `mimir-gateway` `docs/planning/2026-07-04-rma-local-provider-and-session-gaps.md` §5: "On sync-run timeout the Session stops but the invoke Task's HTTP stream (and server billing) continues. Fix: shut down the poll Task so Finch tears down the connection; document that server-side `timeoutSeconds` remains the authoritative server budget. No API change."

## Global Constraints

- **Version control is jj, not git.** Commit with `jj describe -m "<message>" && jj new`. Never `git add/commit/push`. Use `--git` on any `jj diff`/`jj show`.
- **Public-repo hygiene:** internal tracker identifiers (`MIM-…`) never appear in commit messages, code, comments, test names, moduledocs, README, CHANGELOG, or PR titles. The ONLY permitted tracker reference is the PR body's trailing `Closes MIM-…` line.
- **No public API change** in this release (patch). New/changed behavior is internal to `Session`.
- Release discipline: version `0.4.1` in `mix.exs`, dated CHANGELOG entry, Keep-a-Changelog format (see existing `CHANGELOG.md` entries).
- Full suite must pass: `mix test` (excludes `:external` by default via `test/test_helper.exs`).

---

### Task 1: Session kills in-flight poll/consumer tasks on termination

**Files:**
- Modify: `lib/req_managed_agents/session.ex` (state map in `init/1` ~line 94; `drive/2` `:request_response` clause ~lines 258–276; `handle_info({:turn, …})` ~lines 217–224; moduledoc lines 24–29; new `terminate/2`)
- Test: `test/req_managed_agents/session_timeout_cancel_test.exs` (create)

**Interfaces:**
- Consumes: existing `Session` internals — `drive/2` spawns the poll task with `Task.start_link`; state already holds `consumer` (the streaming SSE consumer task pid or `nil`).
- Produces: session state gains `poll_task: pid | nil`; a `terminate/2` callback that force-kills `poll_task` and `consumer` when alive. Later releases (0.5.0/0.6.0) build on `Session` but do not depend on these internals by name.

- [ ] **Step 1: Write the failing test**

Create `test/req_managed_agents/session_timeout_cancel_test.exs`:

```elixir
defmodule ReqManagedAgents.SessionTimeoutCancelTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Session

  # :request_response provider whose poll blocks forever — simulates a long
  # in-flight AgentCore invoke holding a Finch stream open.
  defmodule BlockingPoll do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, _subscriber), do: {:ok, %{test_pid: opts[:test_pid]}}
    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}
    @impl true
    def poll_turn(conn, _input) do
      send(conn.test_pid, {:poll_started, self()})
      Process.sleep(:infinity)
    end

    @impl true
    def normalize(_events), do: %ReqManagedAgents.TurnResult{terminal: :end_turn}
  end

  test "run/2 timeout shuts down the in-flight poll task" do
    assert {:error, :timeout} =
             Session.run(BlockingPoll,
               handler: fn _n, _i, _c -> {:ok, ""} end,
               test_pid: self(),
               timeout: 100
             )

    assert_receive {:poll_started, task_pid}, 1_000
    ref = Process.monitor(task_pid)
    # Monitoring an already-dead pid still delivers :DOWN immediately, so this
    # asserts "dead now or dies promptly" either way.
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, 1_000
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/req_managed_agents/session_timeout_cancel_test.exs`
Expected: 1 failure — the `{:DOWN, …}` never arrives (the poll task survives the `:normal` stop because `Session` exits with reason `:normal` and the linked task ignores `:normal` exit signals). The `{:error, :timeout}` assertion passes.

- [ ] **Step 3: Implement the fix in `Session`**

Three edits in `lib/req_managed_agents/session.ex`:

**(a)** In `init/1`, add `poll_task: nil` to the state map (next to `consumer: Map.get(conn, :consumer)`):

```elixir
          ref: Map.get(conn, :ref),
          consumer: Map.get(conn, :consumer),
          poll_task: nil,
```

**(b)** In the `:request_response` `drive/2` clause, capture and record the task pid (currently the `Task.start_link` return is unbound):

```elixir
  defp drive(%{mode: :request_response} = s, input) do
    parent = self()
    %{provider: p, conn: c} = s

    {:ok, task} =
      Task.start_link(fn ->
        # Convert a provider raise into a surfaced error so it can't crash the Session (and, for a
        # sync run/2, the caller) — the {:ok}|{:error} contract holds even on malformed data.
        result =
          try do
            p.poll_turn(c, input)
          rescue
            e -> {:error, {:provider_error, e}}
          end

        send(parent, {:turn, result})
      end)

    {:noreply, %{s | poll_task: task}}
  end
```

And clear it when the turn lands — in `handle_info({:turn, {:ok, events, conn}}, s)` change the `handle_turn` call to:

```elixir
    handle_turn(%{s | conn: conn, live_forwarded: 0, poll_task: nil}, events)
```

**(c)** Add `terminate/2` (place it after `handle_cast/2`, before the private section). `Session` traps exits, so `terminate/2` runs on every stop path — including the `GenServer.stop(pid, :normal)` issued by `run/2` on timeout:

```elixir
  @impl true
  # Session traps exits, so this runs on every stop — including run/2's timeout
  # stop. Linked poll/consumer tasks ignore a :normal exit signal, so an
  # in-flight AgentCore invoke (or SSE consumer) would otherwise keep its HTTP
  # stream — and server-side billing — alive after the caller got :timeout.
  def terminate(_reason, s) do
    shutdown(s.poll_task)
    shutdown(s.consumer)
  end

  # Killing an already-dead pid is a harmless no-op — no liveness check needed.
  defp shutdown(pid) when is_pid(pid), do: Process.exit(pid, :kill)
  defp shutdown(_other), do: :ok
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/req_managed_agents/session_timeout_cancel_test.exs`
Expected: PASS (the poll task dies with `:killed`).

- [ ] **Step 5: Update the `Session` moduledoc**

The moduledoc currently documents the bug as behavior (lines 24–29). Replace:

```
  For long AgentCore runs set `:timeout` (the end-to-end run budget, default 600_000 ms)
  at or above the server-side budget — a `run/2` timeout returns `{:error, :timeout}` but does
  NOT cancel the in-flight invoke; the harness keeps executing (and billing) server-side up to
  its own `timeoutSeconds`. Transport liveness is guarded per turn by `:idle_timeout` and total
```

with:

```
  For long AgentCore runs set `:timeout` (the end-to-end run budget, default 600_000 ms)
  at or above the server-side budget — a `run/2` timeout returns `{:error, :timeout}` and
  tears down the in-flight invoke client-side (the poll task and its HTTP stream are shut
  down). The server may still run the already-received invocation to its own limit: the
  server-side `timeoutSeconds` remains the authoritative server budget.
  Transport liveness is guarded per turn by `:idle_timeout` and total
```

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: all green (no `:external` tests run by default). Pay attention to `session_resilience_test.exs` / `session_reconnect_test.exs` — they exercise consumer-task crash paths and must not be affected by the new `terminate/2`.

- [ ] **Step 7: Commit**

```bash
jj describe -m "fix(session): run/2 timeout shuts down in-flight poll/consumer tasks

A sync-run timeout stopped the Session with reason :normal; the linked
poll task (AgentCore invoke) and SSE consumer ignored the :normal exit
signal and kept their HTTP streams open. terminate/2 now kills them so
Finch tears down the connection. Server-side timeoutSeconds remains the
authoritative server budget (moduledoc updated)." && jj new
```

---

### Task 2: QA-CHECKPOINT — timeout-cancel release gate

**Files:**
- Create: `docs/qa/<run-date>-timeout-cancel-manual-test.md` (the runbook; header per house style: Date / Tester / Commits under test / Worktree / Scope — no tracker ids)
- Scratch (author, run, then DELETE before committing): `test/qa_timeout_cancel_scratch.exs`

**Interfaces:**
- Consumes: Task 1.
- Produces: a PASS verdict recorded in the runbook. **Task 3 (release) does not start until this task reports PASS.** Failures become fix tasks against Task 1, then this checkpoint re-runs.

- [ ] **Step 1: Baseline**

Run: `mix test 2>&1 | grep -E "^(Finished|Result)"` — record the counts in the runbook. The final step must reproduce them exactly.

- [ ] **Step 2: Author and run the scratch scenarios**

Each scenario targets what the unit test (single fake-provider timeout) does NOT prove. Record motivation, method, real output, and verdict per scenario in the runbook:

| # | Scenario | Method | Expected |
|---|---|---|---|
| 1 | Repeated timeouts don't leak processes | Record `length(Process.list())`; run 10 `Session.run` timeouts against a blocking-poll fake (100ms timeout); wait 500ms | Process count returns to within ±2 of the baseline (poll tasks all killed, no monotonic growth) |
| 2 | Wire-level stream teardown (the actual bug) | Bypass SSE endpoint whose handler loops: `Plug.Conn.chunk` every 100ms, sending the test pid `:chunk_ok` after each successful write; drive a Claude Managed Agents `Session.run` (`client` pointed at Bypass) with `timeout: 300` | `{:error, :timeout}` returned; `:chunk_ok` messages STOP arriving within ~1s of the timeout (the chunk write starts failing because Finch closed the connection) — the pre-fix behavior is chunks flowing for the server's whole lifetime |
| 3 | Live-session stop tears down too | `Session.start_link` on the same Bypass SSE; `GenServer.stop(pid)` | Same chunk-stop proof as scenario 2 (terminate/2 covers every stop path, not just run/2 timeout) |
| 4 | Normal completion unaffected | Run a scripted request/response fake to `:end_turn` | `{:ok, %SessionResult{}}` unchanged; no stray `:DOWN`/`:EXIT` messages in the test mailbox |

- [ ] **Step 3: Clean up and confirm the baseline**

Delete the scratch file, then re-run: `mix test 2>&1 | grep -E "^(Finished|Result)"`
Expected: identical counts to Step 1. Record in the runbook.

- [ ] **Step 4: Write the verdict and commit the runbook**

The runbook ends with an explicit `RESULT: PASS — N/N scenarios` (or the failure list). Commit:

```bash
jj describe -m "qa: timeout-cancel release-gate checkpoint (PASS)" && jj new
```

---

### Task 3: Release 0.4.1 — version bump + CHANGELOG

**Files:**
- Modify: `mix.exs:4` (`@version "0.4.0"` → `@version "0.4.1"`)
- Modify: `CHANGELOG.md` (new entry above `## v0.4.0`)

**Interfaces:**
- Consumes: Task 1's behavior change (the CHANGELOG entry describes it); Task 2's PASS verdict.
- Produces: version `0.4.1` — the 0.5.0 plan bumps from this.

- [ ] **Step 1: Bump the version**

In `mix.exs` change:

```elixir
  @version "0.4.1"
```

- [ ] **Step 2: Add the CHANGELOG entry**

Insert directly under the header block of `CHANGELOG.md` (above `## v0.4.0 (2026-07-04)`):

```markdown
## v0.4.1 (2026-07-04)

### Fixed
- `Session.run/2` timeout now shuts down the in-flight poll task (Bedrock AgentCore
  invoke) and the streaming SSE consumer, so the client HTTP stream is torn down
  instead of continuing after the caller received `{:error, :timeout}`. Server-side
  execution may still run to the provider's own limit — on AgentCore, `timeoutSeconds`
  remains the authoritative server budget (Session moduledoc updated to match).
```

- [ ] **Step 3: Verify the release builds clean**

Run: `mix test && mix docs`
Expected: suite green; docs build without warnings.

- [ ] **Step 4: Commit**

```bash
jj describe -m "release: v0.4.1 — timeout-cancel fix (version bump + CHANGELOG)" && jj new
```
