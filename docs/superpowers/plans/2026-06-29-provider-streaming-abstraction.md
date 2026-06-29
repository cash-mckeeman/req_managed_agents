# Provider Streaming Abstraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce a `ReqManagedAgents.Provider` behaviour and a single canonical turn vocabulary, then refactor RMA's two existing streaming backends (Bedrock AgentCore, Anthropic Managed Agents) to implement it, so a third backend is one behaviour implementation rather than a new event shape threaded through the drivers.

**Architecture:** Three layers. Transport (`SSE.decode/1`, `EventStream.decode/1`) and the driver result shape (`{:ok, %{terminal, stop_reason, events}}`) are already convergent. The new middle layer is `normalize/1` (events → canonical `turn_outcome`), `terminal/1` (raw stop reason → canonical atom), and `resume/2` (canonical results → provider continuation). Two thin provider modules (`Providers.AgentCore`, `Providers.ManagedAgents`) compose the existing internals; the two drivers keep their distinct loop topologies but speak the canonical vocabulary.

**Tech Stack:** Elixir, ExUnit, `jason`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-06-29-provider-streaming-abstraction-design.md`

## Global Constraints

- **Canonical vocabulary is Anthropic's `custom_tool_use` / `custom_tool_result`.** A `custom_tool_use` is `%{id: String.t(), name: String.t(), input: map()}`. A `custom_tool_result` is `%{tool_use_id: String.t(), text: String.t(), is_error: boolean()}`. These name the **client-side / return-of-control** species only.
- **`normalize/1` MUST surface only custom (client-side) tool uses** in `turn_outcome.custom_tool_uses`. Server-side / built-in tool activity stays in raw `events` and is never named `custom_*`. This is the repository thesis (provider-managed loop, locally executed tools) and the load-bearing invariant.
- **Terminal taxonomy is exactly three atoms:** `:end_turn | :requires_action | :terminated`. The raw provider string is always preserved in `turn_outcome.stop_reason`.
- **`turn_outcome`** is `%{terminal: terminal(), stop_reason: String.t() | nil, custom_tool_uses: [custom_tool_use()], text: String.t()}`. `custom_tool_uses` is non-empty iff `terminal == :requires_action`. `text` is best-effort.
- **No change to `ReqManagedAgents.Tools`.** `Tools.run/6` keeps returning the `user.custom_tool_result` wire event.
- **Module namespace:** `ReqManagedAgents.Providers.{AgentCore,ManagedAgents}`.
- **Server-side observability is out of scope for v1** — no `server_tool_uses` field.
- **`decode/1` stays in the behaviour** (providers delegate to `SSE`/`EventStream`); v1 does **not** rewire `Client`/`Stream` to call it — they keep calling the transport modules directly. The callback is exercised by conformance tests.
- Atom-keyed canonical types are RMA-internal; wire maps remain string-keyed.

---

### Task 1: `Provider` behaviour, canonical types, and `result_of/2` helper

**Files:**
- Create: `lib/req_managed_agents/provider.ex`
- Test: `test/req_managed_agents/provider_test.exs`

**Interfaces:**
- Produces: the `ReqManagedAgents.Provider` behaviour with callbacks `decode/1`, `normalize/1`, `terminal/1`, `resume/2`; the types `custom_tool_use/0`, `custom_tool_result/0`, `terminal/0`, `turn_outcome/0`, `event/0`; and the plain function `result_of/2 :: (String.t(), map()) -> custom_tool_result()`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/req_managed_agents/provider_test.exs
defmodule ReqManagedAgents.ProviderTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Provider

  test "declares the four provider callbacks" do
    callbacks = Provider.behaviour_info(:callbacks)
    assert {:decode, 1} in callbacks
    assert {:normalize, 1} in callbacks
    assert {:terminal, 1} in callbacks
    assert {:resume, 2} in callbacks
  end

  test "result_of/2 extracts a canonical custom_tool_result from a Tools.run wire event" do
    wire = %{
      "type" => "user.custom_tool_result",
      "custom_tool_use_id" => "tu_1",
      "content" => [%{"type" => "text", "text" => "echoed: hi"}],
      "is_error" => false
    }

    assert Provider.result_of("tu_1", wire) ==
             %{tool_use_id: "tu_1", text: "echoed: hi", is_error: false}
  end

  test "result_of/2 defaults missing text to \"\" and treats is_error truthiness strictly" do
    assert Provider.result_of("tu_2", %{"is_error" => true}) ==
             %{tool_use_id: "tu_2", text: "", is_error: true}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/req_managed_agents/provider_test.exs`
Expected: FAIL — `ReqManagedAgents.Provider` is undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/req_managed_agents/provider.ex
defmodule ReqManagedAgents.Provider do
  @moduledoc """
  Contract a streaming agent backend implements so RMA's drivers can speak one
  canonical turn vocabulary regardless of wire protocol (binary EventStream vs SSE)
  or invocation model (per-turn request/response vs long-lived push stream). Both
  backends are stateful, session-scoped.

  The canonical vocabulary uses Anthropic's `custom_tool_use` / `custom_tool_result`
  terms and names ONLY the client-side / return-of-control species. Server-side /
  built-in tool activity stays in the raw `events` and is never represented here —
  the repository thesis is a provider-managed loop with locally executed tools.
  """

  @typedoc "A raw, decoded provider event (string-keyed wire map)."
  @type event :: %{required(String.t()) => term()}

  @typedoc "A client-side (return-of-control) tool call the client executes locally."
  @type custom_tool_use :: %{id: String.t(), name: String.t(), input: map()}

  @typedoc "A locally-produced result for a custom_tool_use — what the client submits to resume."
  @type custom_tool_result :: %{tool_use_id: String.t(), text: String.t(), is_error: boolean()}

  @type terminal :: :end_turn | :requires_action | :terminated

  @type turn_outcome :: %{
          terminal: terminal(),
          stop_reason: String.t() | nil,
          custom_tool_uses: [custom_tool_use()],
          text: String.t()
        }

  @doc "Reduce a streaming byte buffer to decoded events + leftover. (Transport seam.)"
  @callback decode(binary()) :: {[event()], binary()}

  @doc """
  Fold one turn's accumulated events into the canonical turn outcome. MUST surface
  only custom (client-side) tool calls in `custom_tool_uses`; server-side tool
  activity stays in the raw events and out of the actionable path.
  """
  @callback normalize([event()]) :: turn_outcome()

  @doc "Map a provider-raw stop reason to the canonical terminal atom."
  @callback terminal(stop_reason :: String.t() | nil) :: terminal()

  @doc """
  Build the provider-specific continuation that submits locally-executed tool results.
  Opaque to the driver.
  """
  @callback resume(custom_tool_uses :: [custom_tool_use()], results :: [custom_tool_result()]) ::
              term()

  @doc """
  Extract a canonical `custom_tool_result` from a `Tools.run/6` wire event
  (`user.custom_tool_result` shape), given the tool-use id it answers.
  """
  @spec result_of(String.t(), event()) :: custom_tool_result()
  def result_of(id, tool_event) when is_binary(id) and is_map(tool_event) do
    text = get_in(tool_event, ["content", Access.at(0), "text"]) || ""
    %{tool_use_id: id, text: text, is_error: tool_event["is_error"] == true}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/req_managed_agents/provider_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(provider): add Provider behaviour, canonical vocabulary, result_of/2"
jj new
```

---

### Task 2: `Providers.AgentCore` — Bedrock provider over Converse/EventStream

**Files:**
- Create: `lib/req_managed_agents/providers/agent_core.ex`
- Test: `test/req_managed_agents/providers/agent_core_test.exs`

**Interfaces:**
- Consumes: `AgentCore.EventStream.decode/1`, `AgentCore.Converse.parse/1` (`%{stop_reason, tool_uses: [%{"toolUseId","name","input"}], text}`), `AgentCore.Converse.resume_messages/2`, `ReqManagedAgents.Provider`.
- Produces: `@behaviour ReqManagedAgents.Provider` with `decode/1`, `normalize/1`, `terminal/1`, `resume/2`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/req_managed_agents/providers/agent_core_test.exs
defmodule ReqManagedAgents.Providers.AgentCoreTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Providers.AgentCore

  defp start_block(idx, id, name) do
    %{"contentBlockStart" => %{"contentBlockIndex" => idx, "start" => %{"toolUse" => %{"toolUseId" => id, "name" => name}}}}
  end

  defp delta(idx, frag) do
    %{"contentBlockDelta" => %{"contentBlockIndex" => idx, "delta" => %{"toolUse" => %{"input" => frag}}}}
  end

  defp tool_stop, do: %{"messageStop" => %{"stopReason" => "tool_use"}}

  test "normalize/1 maps a tool_use turn to canonical custom_tool_uses + :requires_action" do
    events = [start_block(0, "tu_1", "echo"), delta(0, ~s({"text":"hi"})), tool_stop()]

    assert AgentCore.normalize(events) == %{
             terminal: :requires_action,
             stop_reason: "tool_use",
             custom_tool_uses: [%{id: "tu_1", name: "echo", input: %{"text" => "hi"}}],
             text: ""
           }
  end

  test "normalize/1 maps a normal stop to :end_turn with no custom_tool_uses" do
    events = [
      %{"contentBlockDelta" => %{"contentBlockIndex" => 0, "delta" => %{"text" => "done."}}},
      %{"messageStop" => %{"stopReason" => "end_turn"}}
    ]

    assert %{terminal: :end_turn, stop_reason: "end_turn", custom_tool_uses: [], text: "done."} =
             AgentCore.normalize(events)
  end

  test "terminal/1 collapses to the canonical three atoms" do
    assert AgentCore.terminal("end_turn") == :end_turn
    assert AgentCore.terminal("stop_sequence") == :end_turn
    assert AgentCore.terminal("tool_use") == :requires_action
    assert AgentCore.terminal("max_tokens") == :terminated
    assert AgentCore.terminal("guardrail_intervened") == :terminated
    assert AgentCore.terminal("something_new") == :terminated
    assert AgentCore.terminal(nil) == :terminated
  end

  test "MIM-52 regression: a reused contentBlockIndex recovers BOTH distinct tools" do
    events = [start_block(0, "tu_A", "f"), start_block(0, "tu_B", "g"), tool_stop()]
    ids = Enum.map(AgentCore.normalize(events).custom_tool_uses, & &1.id)
    assert ids == ["tu_A", "tu_B"]
  end

  test "server-side exclusion: unrecognized content events never enter custom_tool_uses" do
    events = [
      %{"contentBlockStart" => %{"contentBlockIndex" => 0, "start" => %{"someServerTool" => %{"name" => "web_search"}}}},
      start_block(1, "tu_1", "echo"),
      delta(1, ~s({})),
      tool_stop()
    ]

    assert [%{id: "tu_1"}] = AgentCore.normalize(events).custom_tool_uses
  end

  test "resume/2 produces the strict two-message Converse resume" do
    uses = [%{id: "tu_1", name: "echo", input: %{"text" => "hi"}}]
    results = [%{tool_use_id: "tu_1", text: "echoed: hi", is_error: false}]

    assert [%{"role" => "assistant", "content" => [%{"toolUse" => tu}]}, user] =
             AgentCore.resume(uses, results)

    assert tu == %{"toolUseId" => "tu_1", "name" => "echo", "input" => %{"text" => "hi"}}
    assert get_in(user, ["content", Access.at(0), "toolResult", "status"]) == "success"
  end

  test "implements the Provider behaviour" do
    callbacks = ReqManagedAgents.Provider.behaviour_info(:callbacks)
    for cb <- callbacks, do: assert function_exported?(AgentCore, elem(cb, 0), elem(cb, 1))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/req_managed_agents/providers/agent_core_test.exs`
Expected: FAIL — `ReqManagedAgents.Providers.AgentCore` is undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/req_managed_agents/providers/agent_core.ex
defmodule ReqManagedAgents.Providers.AgentCore do
  @moduledoc """
  `ReqManagedAgents.Provider` implementation for the Bedrock AgentCore (`vnd.amazon.eventstream`)
  backend. A thin adapter over the existing `AgentCore.EventStream` and `AgentCore.Converse`.

  `Converse.parse/1` only surfaces `toolUse` content blocks at `stopReason: "tool_use"` —
  these are the return-of-control `inline_function` calls (client-side by construction).
  Harness-executed built-in tools do not produce a `tool_use` stop and never appear here.
  """
  @behaviour ReqManagedAgents.Provider

  alias ReqManagedAgents.AgentCore.{Converse, EventStream}

  @impl true
  def decode(buffer), do: EventStream.decode(buffer)

  @impl true
  def normalize(events) do
    %{stop_reason: reason, tool_uses: tool_uses, text: text} = Converse.parse(events)

    custom_tool_uses =
      Enum.map(tool_uses, fn %{"toolUseId" => id, "name" => name, "input" => input} ->
        %{id: id, name: name, input: input}
      end)

    %{terminal: terminal(reason), stop_reason: reason, custom_tool_uses: custom_tool_uses, text: text}
  end

  @impl true
  def terminal("end_turn"), do: :end_turn
  def terminal("stop_sequence"), do: :end_turn
  def terminal("tool_use"), do: :requires_action
  def terminal(_other), do: :terminated

  @impl true
  def resume(custom_tool_uses, results) do
    wire =
      Enum.map(custom_tool_uses, fn %{id: id, name: name, input: input} ->
        %{"toolUseId" => id, "name" => name, "input" => input}
      end)

    Converse.resume_messages(wire, results)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/req_managed_agents/providers/agent_core_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(providers): add Providers.AgentCore over Converse/EventStream"
jj new
```

---

### Task 3: `Providers.ManagedAgents` — SSE provider with the new normalizer

**Files:**
- Create: `lib/req_managed_agents/providers/managed_agents.ex`
- Test: `test/req_managed_agents/providers/managed_agents_test.exs`

**Interfaces:**
- Consumes: `ReqManagedAgents.SSE.decode/1`, `ReqManagedAgents.Event.custom_tool_result/3`, `ReqManagedAgents.Provider`.
- Produces: `@behaviour ReqManagedAgents.Provider` with `decode/1`, `normalize/1`, `terminal/1`, `resume/2`.
- **Note:** `normalize/1` keys off the **most recent** status event (the driver calls it on session-wide accumulated events); `toolUseId`s are unique across turns so resolving the current `event_ids` against the full set is correct. `text` is best-effort `""` for now — the assistant-text event shape is unconfirmed and is captured in a follow-up; no driver control flow depends on it.

- [ ] **Step 1: Write the failing test**

```elixir
# test/req_managed_agents/providers/managed_agents_test.exs
defmodule ReqManagedAgents.Providers.ManagedAgentsTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Providers.ManagedAgents

  defp use_event(id, name, input),
    do: %{"type" => "agent.custom_tool_use", "id" => id, "name" => name, "input" => input}

  defp idle(reason, event_ids \\ []),
    do: %{"type" => "session.status_idle", "stop_reason" => %{"type" => reason, "event_ids" => event_ids}}

  test "normalize/1 emits requested custom_tool_uses in event_ids order on requires_action" do
    events = [use_event("e1", "f", %{"a" => 1}), use_event("e2", "g", %{"b" => 2}), idle("requires_action", ["e2", "e1"])]

    assert ManagedAgents.normalize(events) == %{
             terminal: :requires_action,
             stop_reason: "requires_action",
             custom_tool_uses: [
               %{id: "e2", name: "g", input: %{"b" => 2}},
               %{id: "e1", name: "f", input: %{"a" => 1}}
             ],
             text: ""
           }
  end

  test "normalize/1 maps an end_turn idle to :end_turn with no custom_tool_uses" do
    assert %{terminal: :end_turn, stop_reason: "end_turn", custom_tool_uses: []} =
             ManagedAgents.normalize([idle("end_turn")])
  end

  test "server-side exclusion: a custom_tool_use NOT in event_ids is not surfaced" do
    # e2 is a provider-executed tool the loop ran itself; only e1 is returned to us.
    events = [use_event("e1", "f", %{}), use_event("e2", "server_search", %{}), idle("requires_action", ["e1"])]
    assert [%{id: "e1"}] = ManagedAgents.normalize(events).custom_tool_uses
  end

  test "normalize/1 uses the MOST RECENT idle (multi-turn accumulated events)" do
    events = [
      use_event("e1", "f", %{}),
      idle("requires_action", ["e1"]),
      use_event("e2", "g", %{}),
      idle("requires_action", ["e2"])
    ]

    assert [%{id: "e2", name: "g"}] = ManagedAgents.normalize(events).custom_tool_uses
  end

  test "terminal/1 collapses to the canonical three atoms" do
    assert ManagedAgents.terminal("end_turn") == :end_turn
    assert ManagedAgents.terminal("requires_action") == :requires_action
    assert ManagedAgents.terminal("retries_exhausted") == :terminated
    assert ManagedAgents.terminal("anything_else") == :terminated
    assert ManagedAgents.terminal(nil) == :terminated
  end

  test "normalize/1 maps a terminated/error stream to :terminated" do
    assert %{terminal: :terminated} = ManagedAgents.normalize([%{"type" => "session.status_terminated"}])
    assert %{terminal: :terminated} = ManagedAgents.normalize([%{"type" => "session.error"}])
  end

  test "resume/2 builds user.custom_tool_result events from canonical results" do
    results = [%{tool_use_id: "e1", text: "ok", is_error: false}, %{tool_use_id: "e2", text: "boom", is_error: true}]
    events = ManagedAgents.resume([], results)

    assert [%{"type" => "user.custom_tool_result", "custom_tool_use_id" => "e1", "is_error" => false} = ok, boom] = events
    assert get_in(ok, ["content", Access.at(0), "text"]) == "ok"
    assert boom["is_error"] == true
  end

  test "implements the Provider behaviour" do
    callbacks = ReqManagedAgents.Provider.behaviour_info(:callbacks)
    for cb <- callbacks, do: assert function_exported?(ManagedAgents, elem(cb, 0), elem(cb, 1))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/req_managed_agents/providers/managed_agents_test.exs`
Expected: FAIL — `ReqManagedAgents.Providers.ManagedAgents` is undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/req_managed_agents/providers/managed_agents.ex
defmodule ReqManagedAgents.Providers.ManagedAgents do
  @moduledoc """
  `ReqManagedAgents.Provider` implementation for the Anthropic Managed Agents (SSE) backend.

  Client-side tool calls arrive as `agent.custom_tool_use` events; a
  `session.status_idle` with `stop_reason.type == "requires_action"` lists the
  `event_ids` requiring local execution. Only those ids are surfaced as
  `custom_tool_uses` — provider-executed tools are not in `event_ids` and stay in
  the raw events. `normalize/1` keys off the most recent status event so it is
  correct when called on session-wide accumulated events.
  """
  @behaviour ReqManagedAgents.Provider

  alias ReqManagedAgents.Event

  @impl true
  def decode(buffer), do: ReqManagedAgents.SSE.decode(buffer)

  @impl true
  def normalize(events) do
    uses_by_id =
      for %{"type" => "agent.custom_tool_use", "id" => id} = e <- events, into: %{}, do: {id, e}

    case latest_status(events) do
      %{"type" => "session.status_idle", "stop_reason" => %{"type" => reason} = sr} ->
        custom_tool_uses =
          sr
          |> Map.get("event_ids", [])
          |> Enum.map(&uses_by_id[&1])
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn e -> %{id: e["id"], name: e["name"], input: e["input"]} end)

        outcome(terminal(reason), reason, custom_tool_uses)

      %{"type" => "session.status_terminated"} ->
        outcome(:terminated, "terminated", [])

      %{"type" => "session.error"} ->
        outcome(:terminated, "error", [])

      nil ->
        outcome(:terminated, nil, [])
    end
  end

  @impl true
  def terminal("end_turn"), do: :end_turn
  def terminal("requires_action"), do: :requires_action
  def terminal(_other), do: :terminated

  @impl true
  def resume(_custom_tool_uses, results) do
    Enum.map(results, fn r ->
      Event.custom_tool_result(r.tool_use_id, r.text, is_error: r.is_error)
    end)
  end

  # `text` is best-effort; the assistant-text event shape is captured in a follow-up.
  defp outcome(terminal, reason, custom_tool_uses),
    do: %{terminal: terminal, stop_reason: reason, custom_tool_uses: custom_tool_uses, text: ""}

  defp latest_status(events) do
    events
    |> Enum.reverse()
    |> Enum.find(fn
      %{"type" => "session.status_idle"} -> true
      %{"type" => "session.status_terminated"} -> true
      %{"type" => "session.error"} -> true
      _ -> false
    end)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/req_managed_agents/providers/managed_agents_test.exs`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(providers): add Providers.ManagedAgents SSE normalizer"
jj new
```

---

### Task 4: Route `AgentCore.invoke_to_completion/1` through `Providers.AgentCore`

**Files:**
- Modify: `lib/req_managed_agents/agent_core.ex`
- Test: `test/req_managed_agents/agent_core/converse_test.exs` (unchanged, must still pass), plus existing `agent_core` driver tests.

**Interfaces:**
- Consumes: `Providers.AgentCore.{normalize, terminal, resume}` (Task 2), `Provider.result_of/2` (Task 1).
- Produces: unchanged public contract `invoke_to_completion/1 :: {:ok, %{terminal, stop_reason, events}} | {:error, term()}`.

- [ ] **Step 1: Run the existing suite to capture the green baseline**

Run: `mix test test/req_managed_agents/agent_core/`
Expected: PASS (baseline before refactor).

- [ ] **Step 2: Replace `Converse.parse` with `Providers.AgentCore.normalize` in `invoke_turn/3`**

In `lib/req_managed_agents/agent_core.ex`, change the alias line:

```elixir
# from:
alias ReqManagedAgents.AgentCore.{Client, Converse}
# to:
alias ReqManagedAgents.AgentCore.Client
alias ReqManagedAgents.{Provider, Tools}
alias ReqManagedAgents.Providers.AgentCore, as: Backend
```

(Remove the existing `alias ReqManagedAgents.Tools` line if now duplicated.)

In `invoke_turn/3`, replace:

```elixir
          nil ->
            parsed = Converse.parse(events)
            emit_tool_use_telemetry(state, parsed)
```

with:

```elixir
          nil ->
            parsed = Backend.normalize(events)
            emit_tool_use_telemetry(state, parsed)
```

- [ ] **Step 3: Rewrite `handle/3` to branch on the canonical `turn_outcome`**

Replace both `handle/3` clauses and `terminal_atom/1` with:

```elixir
  defp handle(state, %{terminal: :requires_action, custom_tool_uses: tool_uses}, deadline) do
    results =
      Enum.map(tool_uses, fn %{id: id, name: name, input: input} ->
        event = Tools.run(state.handler, id, name, input, state.context, state.meta)
        Provider.result_of(id, event)
      end)

    resume = Backend.resume(tool_uses, results)
    loop(state, resume, deadline)
  end

  defp handle(state, %{terminal: terminal, stop_reason: reason}, _deadline) do
    :telemetry.execute(
      [:req_managed_agents, :agent_core, :terminal],
      %{},
      Map.put(state.meta, :terminal, terminal)
    )

    {:ok, %{terminal: terminal, stop_reason: reason, events: state.events}}
  end
```

Delete `terminal_atom/1` (now provided by `Backend.terminal/1`).

- [ ] **Step 4: Update the MIM-52 telemetry sentinel to canonical keys**

Replace the first line of `emit_tool_use_telemetry/2`:

```elixir
# from:
    ids = Enum.map(parsed.tool_uses, & &1["toolUseId"])
# to:
    ids = Enum.map(parsed.custom_tool_uses, & &1.id)
```

- [ ] **Step 5: Run the suite to verify behavior is preserved**

Run: `mix test test/req_managed_agents/agent_core/`
Expected: PASS. The `converse_test.exs` assertions on `Converse.parse/1` itself still pass (Converse is unchanged); the driver now consumes the canonical shape.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(agent_core): drive invoke loop through Providers.AgentCore canonical vocabulary"
jj new
```

---

### Task 5: Route `RunToCompletion` through `Providers.ManagedAgents` + terminal collapse

**Files:**
- Modify: `lib/req_managed_agents/run_to_completion.ex`
- Test: existing `test/req_managed_agents/run_to_completion*` tests must still pass.

**Interfaces:**
- Consumes: `Providers.ManagedAgents.{normalize, resume}` (Task 3), `Provider.result_of/2` (Task 1).
- Produces: unchanged public contract `run/1 :: {:ok, %{terminal, stop_reason, events}} | {:error, term()}`, with `terminal` now drawn from the canonical three atoms.

- [ ] **Step 1: Run the existing suite to capture the green baseline**

Run: `mix test test/req_managed_agents/run_to_completion_test.exs`
Expected: PASS (baseline; adjust the path to the actual test file if named differently).

- [ ] **Step 2: Update aliases**

In `lib/req_managed_agents/run_to_completion.ex`, change:

```elixir
# from:
  alias ReqManagedAgents.{Client, Event, Stream, Tools}
# to:
  alias ReqManagedAgents.{Client, Provider, Stream, Tools}
  alias ReqManagedAgents.Providers.ManagedAgents, as: Backend
```

(`Event` is still used for `Event.user_message/1` in the `:connected` kickoff — keep `Event` in the alias list if so: `alias ReqManagedAgents.{Client, Event, Provider, Stream, Tools}`.)

- [ ] **Step 3: Drop the manual tool-use accumulator and re-route `do_event/3`**

Remove the `agent.custom_tool_use` clause (it stored into `state.tool_uses`) and the `classify`-based clause. Replace the `do_event/3` group with:

```elixir
  defp do_event(state, %{"type" => "session.status_idle"} = event, deadline) do
    outcome = Backend.normalize(state.events)

    case outcome.terminal do
      :requires_action ->
        loop(resolve(state, outcome.custom_tool_uses), deadline)

      terminal ->
        terminal_result(state, terminal, event["stop_reason"])
    end
  end

  defp do_event(state, %{"type" => "session.status_terminated"} = event, deadline),
    do: terminal_result(state, :terminated, event["stop_reason"])

  defp do_event(state, %{"type" => "session.error"} = event, deadline),
    do: terminal_result(state, :terminated, event["stop_reason"])

  defp do_event(state, _event, deadline), do: loop(state, deadline)

  defp terminal_result(state, terminal, stop_reason) do
    :telemetry.execute(
      [:req_managed_agents, :session, :terminal],
      %{},
      Map.put(tel_meta(state), :terminal, terminal)
    )

    {:ok, %{terminal: terminal, stop_reason: stop_reason, events: state.events}}
  end
```

The `state.tool_uses` field is no longer read; leave the initial `tool_uses: %{}` in `run/1`'s state map or remove it — both compile. Prefer removing it for clarity.

- [ ] **Step 4: Rewrite `resolve/2` to take canonical `custom_tool_uses`**

Replace `resolve/2` with:

```elixir
  defp resolve(state, custom_tool_uses) do
    results =
      Enum.map(custom_tool_uses, fn %{id: id, name: name, input: input} ->
        wire = Tools.run(state.handler, id, name, input, state.context, tel_meta(state))
        Provider.result_of(id, wire)
      end)

    events = Backend.resume(custom_tool_uses, results)
    if events != [], do: Client.send_events(state.client, state.session_id, events)
    state
  end
```

- [ ] **Step 5: Run the suite to verify behavior is preserved**

Run: `mix test test/req_managed_agents/run_to_completion_test.exs`
Expected: PASS. If a test asserts a now-collapsed terminal atom (e.g. `:retries_exhausted`), that is the deliberate behavior change handled in Task 7 — note it and proceed; do not weaken the test here.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(run_to_completion): drive loop through Providers.ManagedAgents; collapse terminals"
jj new
```

---

### Task 6: Cross-provider conformance, symmetry, and exclusion tests

**Files:**
- Create: `test/req_managed_agents/provider_conformance_test.exs`

**Interfaces:**
- Consumes: `Providers.AgentCore`, `Providers.ManagedAgents`, `Provider`.

- [ ] **Step 1: Write the conformance/symmetry test**

```elixir
# test/req_managed_agents/provider_conformance_test.exs
defmodule ReqManagedAgents.ProviderConformanceTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Provider
  alias ReqManagedAgents.Providers.{AgentCore, ManagedAgents}

  @providers [AgentCore, ManagedAgents]

  # A requires_action turn expressed in each backend's wire vocabulary.
  defp requires_action_fixture(AgentCore) do
    [
      %{"contentBlockStart" => %{"contentBlockIndex" => 0, "start" => %{"toolUse" => %{"toolUseId" => "x1", "name" => "lookup"}}}},
      %{"contentBlockDelta" => %{"contentBlockIndex" => 0, "delta" => %{"toolUse" => %{"input" => ~s({"q":"hi"})}}}},
      %{"messageStop" => %{"stopReason" => "tool_use"}}
    ]
  end

  defp requires_action_fixture(ManagedAgents) do
    [
      %{"type" => "agent.custom_tool_use", "id" => "x1", "name" => "lookup", "input" => %{"q" => "hi"}},
      %{"type" => "session.status_idle", "stop_reason" => %{"type" => "requires_action", "event_ids" => ["x1"]}}
    ]
  end

  test "every provider implements all Provider callbacks" do
    for provider <- @providers, {fun, arity} <- Provider.behaviour_info(:callbacks) do
      assert function_exported?(provider, fun, arity),
             "#{inspect(provider)} missing #{fun}/#{arity}"
    end
  end

  test "every provider normalizes its requires_action fixture to a well-formed turn_outcome" do
    for provider <- @providers do
      outcome = provider.normalize(requires_action_fixture(provider))

      assert outcome.terminal == :requires_action
      assert [%{id: id, name: name, input: input}] = outcome.custom_tool_uses
      assert is_binary(id) and is_binary(name) and is_map(input)
      assert is_binary(outcome.text)
    end
  end

  test "custom_tool_uses is non-empty iff terminal is :requires_action" do
    for provider <- @providers do
      ra = provider.normalize(requires_action_fixture(provider))
      assert ra.custom_tool_uses != []
    end

    assert AgentCore.normalize([%{"messageStop" => %{"stopReason" => "end_turn"}}]).custom_tool_uses == []
    assert ManagedAgents.normalize([%{"type" => "session.status_idle", "stop_reason" => %{"type" => "end_turn"}}]).custom_tool_uses == []
  end

  test "cross-provider symmetry: both backends produce the same canonical shape (modulo ids/names)" do
    shapes =
      for provider <- @providers do
        provider.normalize(requires_action_fixture(provider))
        |> Map.update!(:custom_tool_uses, fn uses -> Enum.map(uses, &Map.take(&1, [:id, :name])) end)
      end

    assert [a, b] = shapes
    assert a.terminal == b.terminal
    assert length(a.custom_tool_uses) == length(b.custom_tool_uses)
  end
end
```

- [ ] **Step 2: Run test to verify it passes**

Run: `mix test test/req_managed_agents/provider_conformance_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 3: Commit**

```bash
jj describe -m "test(provider): cross-provider conformance, symmetry, and exclusion gates"
jj new
```

---

### Task 7: Terminal-collapse call-site audit and dead-code cleanup

**Files:**
- Audit/modify: any caller of the old richer managed terminal atoms; `lib/req_managed_agents/event.ex` (`classify/1` and its `terminal` type, if now unused).
- Test: full suite.

**Interfaces:**
- Produces: a clean codebase with one terminal taxonomy and no dead `classify/1`/`terminal_atom/1`.

- [ ] **Step 1: Grep for callers of the now-collapsed atoms and `classify/1`**

Run:
```bash
grep -rn ":retries_exhausted\|:unknown_idle\|:requires_action\|Event.classify\|classify(" lib test
```
Expected: a finite list. For each hit outside the provider/driver code changed above, decide: does it pattern-match a driver RESULT's `terminal`? If it matched `:retries_exhausted`/`:unknown_idle`, change it to match `:terminated` and (if it needs the detail) read `stop_reason`.

- [ ] **Step 2: Retire `Event.classify/1` if unused**

`RunToCompletion` no longer calls `Event.classify/1` (Task 5). If the grep shows no remaining callers, delete `classify/1` and the `terminal` `@type` from `lib/req_managed_agents/event.ex`, keeping the outbound builders (`user_message/1`, `custom_tool_result/3`, `tool_confirmation/2`). If a test referenced `classify/1` directly, delete that test (the behavior is now covered by `Providers.ManagedAgents.terminal/1` + conformance tests).

- [ ] **Step 3: Update any test asserting an old terminal atom**

For each test that asserted `terminal: :retries_exhausted` or `:unknown_idle` on a driver result, change the assertion to `terminal: :terminated` and, where the distinction matters, additionally assert on `stop_reason`. Do not weaken assertions beyond this mapping.

- [ ] **Step 4: Run the full suite**

Run: `mix test`
Expected: PASS (entire suite green).

- [ ] **Step 5: Run the smoke task if available (manual verification of the live path)**

Run: `mix req_managed_agents.agent_core.smoke` (only if AWS creds are configured; otherwise skip and note).
Expected: end-to-end invoke → tool → resume cycle completes, confirming the canonical refactor did not change wire behavior.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor: unify terminal taxonomy; retire Event.classify/terminal_atom"
jj new
```

---

## Self-Review

**Spec coverage:**
- `Provider` behaviour + canonical vocabulary → Task 1. ✓
- `Providers.AgentCore` wrapping Converse/EventStream → Task 2. ✓
- `Providers.ManagedAgents` new normalizer → Task 3. ✓
- Driver refactors (both topologies preserved) → Tasks 4, 5. ✓
- Terminal collapse to three atoms → Tasks 2, 3, 5, 7. ✓
- Server-side exclusion (thesis guard) → tests in Tasks 2, 3, and 6. ✓
- Cross-provider symmetry + conformance → Task 6. ✓
- MIM-52 regression preserved → Task 2. ✓
- `decode/1` in behaviour, `Client`/`Stream` not rewired → Tasks 2, 3 (delegation), conformance exercises it. ✓
- No change to `Tools` → honored via `Provider.result_of/2`. ✓

**Known deferrals (called out, not placeholders):**
- `text` for Managed is `""` until a live assistant-text fixture is captured — forward-compatible field, no control-flow dependency.
- Exact server-side event *types* are unconfirmed; exclusion is tested via the real exclusion mechanisms (`event_ids` subsetting for Managed; toolUse-only recognition for Bedrock) plus a synthetic unrecognized event.
- Managed `resume/2` round-trips `Tools.run` output through canonical and back to wire — a minor redundancy, removable later by having `Tools.run` return canonical.

**Type consistency:** `custom_tool_use` is `%{id, name, input}` and `custom_tool_result` is `%{tool_use_id, text, is_error}` everywhere; `turn_outcome` keys (`terminal`, `stop_reason`, `custom_tool_uses`, `text`) are used identically across Tasks 2–6.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-29-provider-streaming-abstraction.md`.**

Two execution options:
1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration. Runs in a jj worktree under `.claude/worktrees/<name>/` (multi-commit work).
2. **Inline Execution** — execute tasks in this session with checkpoints.

Which approach?
