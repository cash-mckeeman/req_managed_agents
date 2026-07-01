# RMA Result Vocabulary & Usage — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give RMA a singular struct-based result vocabulary and surface the canonical turn outcome + token usage the loop already computes.

**Architecture:** Five structs (`TurnResult`, `SessionResult`, `Usage`, `ToolUse`, `ToolResult`). Providers' `normalize/1` returns a per-turn `%TurnResult{}`; the `Session` accumulates them into a whole-run `%SessionResult{}`. Usage is extracted per-turn (Claude from its SSE `usage` events, Bedrock via new Converse `metadata.usage` parsing) and summed. Struct field-access is transparent to existing map-pattern code, so the migration stays green incrementally.

**Tech Stack:** Elixir, ExUnit, Bypass/Req.Test, Jason, jj.

## Global Constraints

- Each commit message ends with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **No backward-compatibility constraint** (pre-alpha, no consumers) — optimize for a clean API.
- The five structs live under the `ReqManagedAgents` namespace, each with `@derive Jason.Encoder`. Only `events` stays a list of raw provider maps (raw-preservation).
- `Provider.normalize/1` returns `%TurnResult{}`; `Session.run/2` + `message/2` deliver `%SessionResult{}`. Providers produce per-turn results; the Session assembles the run result.
- `usage` accumulates: `input_tokens`/`output_tokens` **summed**; `raw` is the **list** of per-turn provider usage objects. `custom_tool_uses`/`server_tool_uses` are **collected** across turns; `text` is the **terminal turn's**; `turns` is the loop-iteration count.
- **USAGE SHAPE ASSUMPTIONS (not yet confirmed against live events — flagged for verification):**
  - Claude: usage rides on an event with a `"usage"` key shaped `%{"input_tokens" => int, "output_tokens" => int}` (matches `OpenTelemetry.Attributes` + the OTel manual-test doc).
  - Bedrock: a Converse `%{"metadata" => %{"usage" => %{"inputTokens" => int, "outputTokens" => int, "totalTokens" => int}}}` frame (standard AWS Converse shape).
  - Extraction is defensive: a missing/absent usage → `TurnResult.usage = nil`, contributing nothing to the sum.

---

### Task 1: The struct vocabulary

**Files:**
- Create: `lib/req_managed_agents/usage.ex`, `tool_use.ex`, `tool_result.ex`, `turn_result.ex`, `session_result.ex`
- Test: `test/req_managed_agents/vocabulary_test.exs`

**Interfaces — Produces:**
- `%ReqManagedAgents.Usage{input_tokens: non_neg_integer(), output_tokens: non_neg_integer(), raw: [map()]}`
- `%ReqManagedAgents.ToolUse{id: String.t() | nil, name: String.t(), input: map()}`
- `%ReqManagedAgents.ToolResult{tool_use_id: String.t(), text: String.t(), is_error: boolean()}`
- `%ReqManagedAgents.TurnResult{terminal:, stop_reason:, text:, custom_tool_uses: [ToolUse], server_tool_uses: [ToolUse], usage: Usage | nil, events: [map]}`
- `%ReqManagedAgents.SessionResult{terminal:, stop_reason:, text:, custom_tool_uses: [ToolUse], server_tool_uses: [ToolUse], usage: Usage, turns: non_neg_integer(), events: [map]}`

- [ ] **Step 1: Write the failing test** — `test/req_managed_agents/vocabulary_test.exs`

```elixir
defmodule ReqManagedAgents.VocabularyTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.{Usage, ToolUse, ToolResult, TurnResult, SessionResult}

  test "structs construct with the documented defaults and encode to JSON" do
    assert %Usage{input_tokens: 0, output_tokens: 0, raw: []} = %Usage{}
    assert %ToolUse{id: "t1", name: "echo", input: %{}} = %ToolUse{id: "t1", name: "echo", input: %{}}
    assert %ToolResult{tool_use_id: "t1", text: "", is_error: false} = %ToolResult{tool_use_id: "t1"}
    assert %TurnResult{terminal: :terminated, custom_tool_uses: [], usage: nil} = %TurnResult{}
    assert %SessionResult{turns: 0, usage: %Usage{}} = %SessionResult{}

    for s <- [%Usage{}, %ToolUse{id: "1", name: "n", input: %{}}, %ToolResult{tool_use_id: "1"},
              %TurnResult{}, %SessionResult{}] do
      assert {:ok, json} = Jason.encode(s)
      assert is_binary(json)
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/req_managed_agents/vocabulary_test.exs`
Expected: FAIL — `ReqManagedAgents.Usage.__struct__/0 is undefined`.

- [ ] **Step 3: Create the five struct modules**

`lib/req_managed_agents/usage.ex`:
```elixir
defmodule ReqManagedAgents.Usage do
  @moduledoc "Token usage — canonical summed counts + the provider's raw usage object(s) verbatim."
  @derive Jason.Encoder
  defstruct input_tokens: 0, output_tokens: 0, raw: []

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          raw: [map()]
        }
end
```

`lib/req_managed_agents/tool_use.ex`:
```elixir
defmodule ReqManagedAgents.ToolUse do
  @moduledoc "A tool call — client-side (custom, return-of-control) or server-side (observe-only)."
  @derive Jason.Encoder
  defstruct [:id, :name, :input]

  @type t :: %__MODULE__{id: String.t() | nil, name: String.t(), input: map()}
end
```

`lib/req_managed_agents/tool_result.ex`:
```elixir
defmodule ReqManagedAgents.ToolResult do
  @moduledoc "The locally-produced result of running a custom tool — what resumes the loop."
  @derive Jason.Encoder
  @enforce_keys [:tool_use_id]
  defstruct [:tool_use_id, text: "", is_error: false]

  @type t :: %__MODULE__{tool_use_id: String.t(), text: String.t(), is_error: boolean()}
end
```

`lib/req_managed_agents/turn_result.ex`:
```elixir
defmodule ReqManagedAgents.TurnResult do
  @moduledoc "The canonical outcome of ONE turn — what `Provider.normalize/1` returns."
  @derive Jason.Encoder
  defstruct terminal: :terminated,
            stop_reason: nil,
            text: "",
            custom_tool_uses: [],
            server_tool_uses: [],
            usage: nil,
            events: []

  @type t :: %__MODULE__{
          terminal: ReqManagedAgents.Provider.terminal(),
          stop_reason: String.t() | map() | nil,
          text: String.t(),
          custom_tool_uses: [ReqManagedAgents.ToolUse.t()],
          server_tool_uses: [ReqManagedAgents.ToolUse.t()],
          usage: ReqManagedAgents.Usage.t() | nil,
          events: [map()]
        }
end
```

`lib/req_managed_agents/session_result.ex`:
```elixir
defmodule ReqManagedAgents.SessionResult do
  @moduledoc "The accumulated outcome of a whole run — what `Session.run/2` and `message/2` deliver."
  @derive Jason.Encoder
  defstruct terminal: :terminated,
            stop_reason: nil,
            text: "",
            custom_tool_uses: [],
            server_tool_uses: [],
            usage: %ReqManagedAgents.Usage{},
            turns: 0,
            events: []

  @type t :: %__MODULE__{
          terminal: ReqManagedAgents.Provider.terminal(),
          stop_reason: String.t() | map() | nil,
          text: String.t(),
          custom_tool_uses: [ReqManagedAgents.ToolUse.t()],
          server_tool_uses: [ReqManagedAgents.ToolUse.t()],
          usage: ReqManagedAgents.Usage.t(),
          turns: non_neg_integer(),
          events: [map()]
        }
end
```

- [ ] **Step 4: Run the test** — `mix test test/req_managed_agents/vocabulary_test.exs` → PASS.
- [ ] **Step 5: Full suite** — `mix compile --warnings-as-errors && mix test` → green (nothing consumes the structs yet).
- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(vocab): TurnResult/SessionResult/Usage/ToolUse/ToolResult structs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
jj new
```

---

### Task 2: Providers + behaviour speak structs (no usage yet)

**Files:**
- Modify: `lib/req_managed_agents/provider.ex` (types, callbacks, `result_of/2`)
- Modify: `lib/req_managed_agents/providers/claude_managed_agents.ex` (`normalize` → `%TurnResult{}`)
- Modify: `lib/req_managed_agents/providers/bedrock_agent_core.ex` (`normalize` → `%TurnResult{}`)
- Test: `test/req_managed_agents/providers/claude_managed_agents_test.exs`, `.../bedrock_agent_core_test.exs`, `test/req_managed_agents/provider_conformance_test.exs`

**Interfaces:**
- Consumes: the Task 1 structs.
- Produces: `normalize/1 :: [event] -> %TurnResult{}` (both providers); `Provider.result_of/2 :: (id, event) -> %ToolResult{}`. `TurnResult.usage` is `nil` in this task (Task 3 fills it).

- [ ] **Step 1: Update the provider tests to expect structs (failing)**

In `test/req_managed_agents/providers/bedrock_agent_core_test.exs`, change the two `normalize` assertions (verify current lines) to:
```elixir
  alias ReqManagedAgents.{TurnResult, ToolUse}

  test "normalize/1 maps a tool_use turn to a %TurnResult{} with %ToolUse{}" do
    events = [
      %{"contentBlockStart" => %{"contentBlockIndex" => 0, "start" => %{"toolUse" => %{"toolUseId" => "t1", "name" => "lookup"}}}},
      %{"contentBlockDelta" => %{"contentBlockIndex" => 0, "delta" => %{"toolUse" => %{"input" => "{}"}}}},
      %{"messageStop" => %{"stopReason" => "tool_use"}}
    ]

    assert %TurnResult{terminal: :requires_action, stop_reason: "tool_use",
             custom_tool_uses: [%ToolUse{id: "t1", name: "lookup"}], server_tool_uses: []} = P.normalize(events)
  end

  test "normalize/1 maps an end_turn to a %TurnResult{}" do
    assert %TurnResult{terminal: :end_turn, stop_reason: "end_turn", custom_tool_uses: [], text: "done."} =
             P.normalize([%{"messageStop" => %{"stopReason" => "end_turn"}}, %{"contentBlockDelta" => %{"contentBlockIndex" => 0, "delta" => %{"text" => "done."}}}])
  end
```

In `test/req_managed_agents/providers/claude_managed_agents_test.exs`, change the two `normalize` assertions to `%TurnResult{}` / `%ToolUse{}` (the shape is otherwise identical — `stop_reason` stays the raw map, `custom_tool_uses` become `%ToolUse{}` structs):
```elixir
  assert %ReqManagedAgents.TurnResult{terminal: :requires_action,
           stop_reason: %{"type" => "requires_action", "event_ids" => ["e2", "e1"]},
           custom_tool_uses: [%ReqManagedAgents.ToolUse{id: "e2", name: "g", input: %{"b" => 2}},
                              %ReqManagedAgents.ToolUse{id: "e1", name: "f", input: %{"a" => 1}}]} = ManagedAgents.normalize(events)
```
and
```elixir
  assert %ReqManagedAgents.TurnResult{terminal: :end_turn, stop_reason: %{"type" => "end_turn"}, custom_tool_uses: []} =
           ManagedAgents.normalize([idle("end_turn")])
```

Update `test/req_managed_agents/provider_conformance_test.exs` — replace the keys-equality assertion:
```elixir
  test "both providers normalize to a %TurnResult{}" do
    bedrock = BedrockAgentCore.normalize([%{"messageStop" => %{"stopReason" => "end_turn"}}])
    claude = ClaudeManagedAgents.normalize([%{"type" => "session.status_idle", "stop_reason" => %{"type" => "end_turn"}}])

    assert %ReqManagedAgents.TurnResult{terminal: :end_turn} = bedrock
    assert %ReqManagedAgents.TurnResult{terminal: :end_turn} = claude
  end
```

- [ ] **Step 2: Run to verify failure** — `mix test test/req_managed_agents/providers/ test/req_managed_agents/provider_conformance_test.exs` → FAIL (normalize returns maps, not `%TurnResult{}`).

- [ ] **Step 3: Update the `Provider` behaviour** — `lib/req_managed_agents/provider.ex`

Replace the `custom_tool_use`, `custom_tool_result`, `server_tool_use`, and `turn_outcome` `@type`s (they're superseded by the structs). Keep `terminal` and `event`. Update the callbacks:
```elixir
  @callback resume_input(tool_uses :: [ReqManagedAgents.ToolUse.t()], results :: [ReqManagedAgents.ToolResult.t()]) :: input()

  @callback normalize([event()]) :: ReqManagedAgents.TurnResult.t()

  @callback reconnect(conn(), subscriber :: pid(), seen :: MapSet.t()) ::
              {:ok, conn(), [ReqManagedAgents.ToolUse.t()], MapSet.t()} | {:error, term()}
```
And `result_of/2`:
```elixir
  @spec result_of(String.t(), event()) :: ReqManagedAgents.ToolResult.t()
  def result_of(id, tool_event) when is_binary(id) and is_map(tool_event) do
    text = get_in(tool_event, ["content", Access.at(0), "text"]) || ""
    %ReqManagedAgents.ToolResult{tool_use_id: id, text: text, is_error: tool_event["is_error"] == true}
  end
```

- [ ] **Step 4: Migrate Claude `normalize`** — `lib/req_managed_agents/providers/claude_managed_agents.ex`

Add `alias ReqManagedAgents.{ToolUse, TurnResult}`. Replace `normalize/1`'s `outcome(...)` calls and the `outcome/4` helper with a `%TurnResult{}` builder, and make `custom_tool_uses`/`server_tool_uses` lists of `%ToolUse{}`:
```elixir
  def normalize(events) do
    uses_by_id = for %{"type" => "agent.custom_tool_use", "id" => id} = e <- events, into: %{}, do: {id, e}

    case latest_status(events) do
      %{"type" => "session.status_idle", "stop_reason" => %{"type" => reason} = sr} ->
        custom =
          sr |> Map.get("event_ids", []) |> Enum.map(&uses_by_id[&1]) |> Enum.reject(&is_nil/1)
          |> Enum.map(fn e -> %ToolUse{id: e["id"], name: e["name"], input: e["input"]} end)

        turn_result(terminal(reason), sr, custom, events)

      %{"type" => "session.status_terminated"} = s -> turn_result(:terminated, s["stop_reason"], [], events)
      %{"type" => "session.error"} = s -> turn_result(:terminated, s["stop_reason"], [], events)
      %{"type" => "session.status_idle"} = s -> turn_result(:terminated, s["stop_reason"], [], events)
      _ -> turn_result(:terminated, nil, [], events)
    end
  end

  defp turn_result(terminal, stop_reason, custom_tool_uses, events) do
    %TurnResult{
      terminal: terminal,
      stop_reason: stop_reason,
      text: assistant_text(events),
      custom_tool_uses: custom_tool_uses,
      server_tool_uses: server_tool_uses(events),
      usage: nil,
      events: events
    }
  end
```
Change `server_tool_uses/1` to build `%ToolUse{}`:
```elixir
  defp server_tool_uses(events) do
    for %{"type" => "agent.tool_use", "name" => name} = e <- events,
        do: %ToolUse{id: e["id"], name: name, input: e["input"] || %{}}
  end
```
Delete the old `outcome/4` helper. (Confirm `resume_input/2` already accesses `r.tool_use_id`/`r.text`/`r.is_error` — `%ToolResult{}` satisfies that unchanged; if it pattern-matches a map, that also matches the struct.)

- [ ] **Step 5: Migrate Bedrock `normalize`** — `lib/req_managed_agents/providers/bedrock_agent_core.ex`

Add `alias ReqManagedAgents.{ToolUse, TurnResult}`. Replace `normalize/1`:
```elixir
  def normalize(events) do
    %{stop_reason: reason, tool_uses: tool_uses, text: text} = Converse.parse(events)

    custom =
      Enum.map(tool_uses, fn %{"toolUseId" => id, "name" => name, "input" => input} ->
        %ToolUse{id: id, name: name, input: input}
      end)

    %TurnResult{
      terminal: terminal(reason),
      stop_reason: reason,
      text: text,
      custom_tool_uses: custom,
      server_tool_uses: [],
      usage: nil,
      events: events
    }
  end
```

- [ ] **Step 5b: Migrate the fake providers** — `test/support/fake_providers.ex`

The fakes' shared `normalize/1` returns a bare map today. Change it to return a `%ReqManagedAgents.TurnResult{}` (alias `ReqManagedAgents.{TurnResult, ToolUse, Usage}`) with the same `terminal`/`stop_reason`/`text`/`events`, `custom_tool_uses`/`server_tool_uses` as `%ToolUse{}` lists, and a **fixed per-turn usage** so accumulation is testable in Task 4:
```elixir
    usage: %Usage{input_tokens: 1, output_tokens: 1, raw: [%{}]}
```
(Read the file: replace wherever it builds the outcome map. If a fake's `resume_input` reads results, it accesses `%ReqManagedAgents.ToolResult{}` fields — `r.tool_use_id`/`r.text`/`r.is_error` — which is struct-compatible.) This keeps `session_loop_test`/`session_test` green and gives every fake turn a usage of `1/1`.

- [ ] **Step 6: Run provider tests** — `mix test test/req_managed_agents/providers/ test/req_managed_agents/provider_conformance_test.exs` → PASS.
- [ ] **Step 7: Full suite** — `mix compile --warnings-as-errors && mix test` → green. (The Session's `outcome.terminal`/`outcome.custom_tool_uses`, `run_tools`' `%{id, name, input}` match, `emit_tool_use_telemetry`'s `& &1.id`, and `resume_input` all work transparently on the structs; the run result is still a bare map until Task 4.)
- [ ] **Step 8: Commit**

```bash
jj describe -m "refactor(provider): normalize returns %TurnResult{}; result_of returns %ToolResult{}

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
jj new
```

---

### Task 3: Token usage extraction (both providers)

**Files:**
- Modify: `lib/req_managed_agents/agent_core/converse.ex` (parse `metadata.usage`)
- Modify: `lib/req_managed_agents/providers/bedrock_agent_core.ex` (`normalize` → `%Usage{}`)
- Modify: `lib/req_managed_agents/providers/claude_managed_agents.ex` (`turn_result` → `%Usage{}`)
- Test: the two provider tests + `test/req_managed_agents/agent_core/converse_test.exs`

**Interfaces:**
- Consumes: `%ReqManagedAgents.Usage{}`. `Converse.parse/1` gains a `:usage` key (`map() | nil`).
- Produces: `TurnResult.usage` is a `%Usage{input_tokens, output_tokens, raw: [that provider usage map]}` (or `nil` when the turn carries no usage).

> **Usage shapes are assumptions** (see Global Constraints) — Claude `%{"input_tokens", "output_tokens"}`, Bedrock `metadata.usage %{"inputTokens", "outputTokens", "totalTokens"}`. Extraction defaults absent fields to `0` and returns `nil` when no usage frame is present.

- [ ] **Step 1: Write failing tests**

Add to `test/req_managed_agents/agent_core/converse_test.exs`:
```elixir
  test "parse/1 extracts metadata.usage" do
    events = [
      %{"messageStop" => %{"stopReason" => "end_turn"}},
      %{"metadata" => %{"usage" => %{"inputTokens" => 12, "outputTokens" => 7, "totalTokens" => 19}}}
    ]

    assert %{usage: %{"inputTokens" => 12, "outputTokens" => 7}} = ReqManagedAgents.AgentCore.Converse.parse(events)
  end
```

Add to `test/req_managed_agents/providers/bedrock_agent_core_test.exs`:
```elixir
  test "normalize/1 surfaces usage from the Converse metadata frame" do
    events = [%{"messageStop" => %{"stopReason" => "end_turn"}},
              %{"metadata" => %{"usage" => %{"inputTokens" => 12, "outputTokens" => 7, "totalTokens" => 19}}}]

    assert %ReqManagedAgents.TurnResult{usage: %ReqManagedAgents.Usage{input_tokens: 12, output_tokens: 7, raw: [%{"inputTokens" => 12}]}} =
             P.normalize(events)
  end
```

Add to `test/req_managed_agents/providers/claude_managed_agents_test.exs`:
```elixir
  test "normalize/1 surfaces usage from a usage-bearing event" do
    events = [
      %{"type" => "agent.message", "content" => [%{"type" => "text", "text" => "hi"}], "usage" => %{"input_tokens" => 10, "output_tokens" => 5}},
      idle("end_turn")
    ]

    assert %ReqManagedAgents.TurnResult{usage: %ReqManagedAgents.Usage{input_tokens: 10, output_tokens: 5, raw: [%{"input_tokens" => 10}]}} =
             ManagedAgents.normalize(events)
  end
```

- [ ] **Step 2: Run to verify failure** — `mix test test/req_managed_agents/agent_core/converse_test.exs test/req_managed_agents/providers/` → FAIL.

- [ ] **Step 3: Add Converse usage parsing** — `lib/req_managed_agents/agent_core/converse.ex`

Add `usage: nil` to the `init` map in `parse/1`, add a `reduce_event` clause for the metadata frame (place it before the catch-all), and return `usage` from `parse/1`:
```elixir
  # inside parse/1: init
  init = %{stop_reason: nil, blocks: %{}, active: %{}, order: [], text: "", usage: nil}

  # ...at the end of parse/1, add usage to the returned map:
  %{stop_reason: state.stop_reason, tool_uses: tool_uses, text: state.text, usage: state.usage}

  # new reduce_event clause (before the catch-all `defp reduce_event(_, state), do: state`):
  defp reduce_event(%{"metadata" => %{"usage" => usage}}, state), do: %{state | usage: usage}
```

- [ ] **Step 4: Map Bedrock usage** — `lib/req_managed_agents/providers/bedrock_agent_core.ex`

In `normalize/1`, read `usage` from `Converse.parse` and build `%Usage{}` (alias `ReqManagedAgents.Usage`):
```elixir
  def normalize(events) do
    %{stop_reason: reason, tool_uses: tool_uses, text: text, usage: usage} = Converse.parse(events)

    custom = Enum.map(tool_uses, fn %{"toolUseId" => id, "name" => name, "input" => input} -> %ToolUse{id: id, name: name, input: input} end)

    %TurnResult{terminal: terminal(reason), stop_reason: reason, text: text,
      custom_tool_uses: custom, server_tool_uses: [], usage: to_usage(usage), events: events}
  end

  defp to_usage(%{} = u), do: %Usage{input_tokens: u["inputTokens"] || 0, output_tokens: u["outputTokens"] || 0, raw: [u]}
  defp to_usage(_), do: nil
```

- [ ] **Step 5: Map Claude usage** — `lib/req_managed_agents/providers/claude_managed_agents.ex`

Alias `ReqManagedAgents.Usage`; in `turn_result/4`, set `usage: claude_usage(events)`:
```elixir
  defp claude_usage(events) do
    case Enum.find_value(events, fn ev -> ev["usage"] end) do
      %{} = u -> %Usage{input_tokens: u["input_tokens"] || 0, output_tokens: u["output_tokens"] || 0, raw: [u]}
      _ -> nil
    end
  end
```

- [ ] **Step 6: Run tests** — `mix test test/req_managed_agents/agent_core/converse_test.exs test/req_managed_agents/providers/` → PASS.
- [ ] **Step 7: Full suite** — `mix compile --warnings-as-errors && mix test` → green.
- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(usage): extract token usage in normalize (Claude events + Bedrock Converse metadata)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
jj new
```

---

### Task 4: Session assembles %SessionResult{} (+ notify, message reset)

**Files:**
- Modify: `lib/req_managed_agents/session.ex`
- Test: `test/req_managed_agents/session_test.exs` (notify assertion), + a new accumulation test in `test/req_managed_agents/session_loop_test.exs`

**Interfaces:**
- Consumes: `%TurnResult{}` from providers; `%Usage{}`, `%SessionResult{}`.
- Produces: `Session.run/2` + `message/2` deliver `{:ok, %SessionResult{}}`; live `notify` sends `{:managed_agents_session, %SessionResult{}}`.

- [ ] **Step 1: Write failing tests**

Update the notify assertion in `test/req_managed_agents/session_test.exs` (find the current `{:managed_agents_session, :end_turn}` assert) to:
```elixir
    assert_receive {:managed_agents_session, %ReqManagedAgents.SessionResult{terminal: :end_turn}}
```

In `test/req_managed_agents/session_loop_test.exs`, the existing tests drive each fake provider through `requires_action → tools → resume → end_turn` (2 turns, 1 custom tool) and currently assert `{:ok, %{terminal: :end_turn}}`. Strengthen that to check the accumulated `%SessionResult{}` — the fakes now emit `usage: 1/1` per turn (Task 2, Step 5b), so a 2-turn run sums to `2/2`:
```elixir
  assert {:ok, %ReqManagedAgents.SessionResult{
           terminal: :end_turn,
           turns: 2,
           custom_tool_uses: [%ReqManagedAgents.ToolUse{}],
           usage: %ReqManagedAgents.Usage{input_tokens: 2, output_tokens: 2, raw: [_, _]}
         }} = result
```
Apply to both the `:request_response` and `:streaming` loop tests. The invariant is `usage.input_tokens == turns` (fixed `1/1` per turn) with one `raw` entry per turn; if a scenario's turn/tool counts differ, adjust `turns`/`usage`/`custom_tool_uses` to match its script.

- [ ] **Step 2: Run to verify failure** — `mix test test/req_managed_agents/session_test.exs test/req_managed_agents/session_loop_test.exs` → FAIL.

- [ ] **Step 3: Add accumulators to Session state** — `lib/req_managed_agents/session.ex`

In `init`, add to the state map:
```elixir
      custom_tool_uses: [], server_tool_uses: [], usage: %ReqManagedAgents.Usage{input_tokens: 0, output_tokens: 0, raw: []},
```
Add `alias ReqManagedAgents.{Usage, SessionResult, TurnResult}` near the top.

- [ ] **Step 4: Accumulate in `handle_turn` and build the result in `finish`**

Replace `handle_turn/2` and `finish/3`:
```elixir
  defp handle_turn(s, turn_events) do
    s = %{s | events: s.events ++ turn_events, turns: s.turns + 1}
    tr = s.provider.normalize(turn_events)
    s = accumulate(s, tr)
    emit_tool_use_telemetry(s, tr.custom_tool_uses)

    cond do
      s.turns > s.max_turns ->
        notify(s, :terminated)
        stop_error(s, {:max_turns_exceeded, s.max_turns})

      tr.terminal == :requires_action ->
        results = run_tools(tr.custom_tool_uses, s)
        drive(s, s.provider.resume_input(tr.custom_tool_uses, results))

      true ->
        finish(s, tr)
    end
  end

  defp accumulate(s, %TurnResult{} = tr) do
    %{s |
      custom_tool_uses: s.custom_tool_uses ++ tr.custom_tool_uses,
      server_tool_uses: s.server_tool_uses ++ tr.server_tool_uses,
      usage: add_usage(s.usage, tr.usage)}
  end

  defp add_usage(acc, nil), do: acc
  defp add_usage(acc, %Usage{} = u),
    do: %Usage{input_tokens: acc.input_tokens + u.input_tokens, output_tokens: acc.output_tokens + u.output_tokens, raw: acc.raw ++ u.raw}

  defp finish(s, %TurnResult{} = tr) do
    :telemetry.execute([:req_managed_agents, :session, :terminal], %{}, Map.put(s.meta, :terminal, tr.terminal))

    result = %SessionResult{
      terminal: tr.terminal, stop_reason: tr.stop_reason, text: tr.text,
      custom_tool_uses: s.custom_tool_uses, server_tool_uses: s.server_tool_uses,
      usage: s.usage, turns: s.turns, events: s.events
    }

    notify(s, result)
    reply(%{s | reconnect_attempts: 0}, {:ok, result})
  end
```

- [ ] **Step 5: `notify` forwards any payload; `message/2` resets accumulators**

```elixir
  defp notify(%{notify: pid}, payload) when is_pid(pid), do: send(pid, {:managed_agents_session, payload})
  defp notify(_s, _payload), do: :ok
```
(This handles both `%SessionResult{}` from `finish` and the `:terminated` atom from the max-turns path.) And:
```elixir
  def handle_cast({:message, text}, s),
    do: drive(reset_acc(%{s | turns: 0}), s.provider.user_input(text))

  defp reset_acc(s),
    do: %{s | custom_tool_uses: [], server_tool_uses: [], usage: %Usage{input_tokens: 0, output_tokens: 0, raw: []}}
```

- [ ] **Step 6: Run tests** — `mix test test/req_managed_agents/session_test.exs test/req_managed_agents/session_loop_test.exs` → PASS. (Existing `{:ok, %{terminal: :end_turn, events: e}}` assertions in `run_to_completion_test`/`agent_core_test`/`session_loop_test` still pass — `%SessionResult{}` matches those map patterns.)
- [ ] **Step 7: Full suite + both seeds** — `mix compile --warnings-as-errors && mix test && mix test --seed 0` → green.
- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(session): assemble %SessionResult{} (accumulated usage/tool-uses/turns); notify delivers it

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
jj new
```

---

### Task 5: QA sweep — struct-aware captures + equivalence

**Files:**
- Modify (if needed): `qa/checkpoint_capture_test.exs`, `qa/provisioning_smoke_test.exs`
- Test: run `mix req_managed_agents.qa_checkpoint` + `mix req_managed_agents.qa_provisioning`

**Interfaces:** Consumes `%SessionResult{}` from `Session.run`.

- [ ] **Step 1: Confirm the captures still read the result**

`qa/checkpoint_capture_test.exs` pattern-matches `{:ok, %{terminal: t, stop_reason: sr, events: ev}}` and `qa/provisioning_smoke_test.exs` reads `run.terminal` — both work unchanged on a `%SessionResult{}` (struct matches map pattern / field access). No edit required unless a run raises; verify by running the tasks (Step 2). If either needs a struct alias, add it.

- [ ] **Step 2: Run both QA tasks**

Run: `mix req_managed_agents.qa_provisioning`
Expected: `2/2 provider lifecycles healthy`.

Run: `mix req_managed_agents.qa_checkpoint`
Expected: `7/7 scenarios behaviorally identical` (the enrichment is additive; the fingerprint fields are unchanged).

- [ ] **Step 3: Full suite** — `mix compile --warnings-as-errors && mix test && mix test --seed 0` → green.
- [ ] **Step 4: Commit** (only if any capture edits were needed)

```bash
jj describe -m "test(qa): struct-aware captures; qa_checkpoint stays 7/7 after result enrichment

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
jj new
```

---

## Out of scope

- The biai-managed-agents `ResultMapper` slim-down (downstream consumer; MIM-39).
- Cost calculation from usage.

## Verification checklist (after Task 5)

- `mix compile --warnings-as-errors` clean; `mix test` + `--seed 0` green.
- `Session.run` returns `%SessionResult{}` with summed `usage`, collected tool-uses, `turns`, final `text`.
- `Provider.normalize/1` returns `%TurnResult{}`; `qa_checkpoint` 7/7; `qa_provisioning` 2/2.
- **Flag for review:** the Claude usage-event and Bedrock `metadata.usage` shapes are assumptions — confirm against a live event capture before relying on the token counts in production.
