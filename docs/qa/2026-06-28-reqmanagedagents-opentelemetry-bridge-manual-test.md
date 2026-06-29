# ReqManagedAgents.OpenTelemetry bridge — manual test guide

**Date:** 2026-06-28
**Branch/commit context:** `ryan/mim-47-upstream-req_managed_agents-reqmanagedagentsopentelemetry` tip `89dbdac7`
**Tester:** QA checkpoint subagent (author-mode)
**Environment:** darwin, worktree `/Users/ryanmckeeman/src/bizinsights/req_managed_agents/.claude/worktrees/otel-bridge`

---

**Scope:** This checkpoint validates the `ReqManagedAgents.OpenTelemetry` bridge — the pure-mapper and optional-OTLP-export surface that normalises RMA `:telemetry` metadata into OTel GenAI (`gen_ai.*`) attribute maps. Covered: `SemConv.provider_name/0` and `finish_reason/1`; all four `Attributes.*` mappers (`invoke_agent/1`, `chat/1`, `tool/1`, `terminal/1`) including both string-keyed Anthropic usage and atom-keyed usage shapes; privacy (content-ish keys must not leak into output maps); `attributes_for/2` dispatch for each real RMA event name with both atom- and string-keyed `type`; an integration pass via real `:telemetry.execute` calls with a `mimir_request_id` correlation key; and the `attach/1` / `available?/0` / `detach/1` lifecycle.

**Read this first:**

1. **No credentials or Bypass server needed.** All steps are pure function calls via `mix run -e`. The lib is compiled and deps are installed. Nothing in this surface touches HTTP or the Anthropic API.
2. **OTel SDK is NOT present in this environment.** `available?/0` returns `false`. `attach/1` returns `{:error, :opentelemetry_unavailable}`. Section E verifies this is the expected no-op path. Steps are not blocked by this absence.
3. **All `mix run -e` commands assume `cwd` is the worktree root.** Run from `/Users/ryanmckeeman/src/bizinsights/req_managed_agents/.claude/worktrees/otel-bridge`.
4. **Privacy invariant.** The bridge must NEVER include metadata keys like `input`, `content`, or `result` in its output maps. Sections B.8 and B.9 verify this against each mapper.
5. **AgentCore is intentionally out of scope.** This bridge only maps `[:req_managed_agents, :stream|:tool|:session, …]` events. AgentCore (`[:req_managed_agents, :agent_core, …]`) is not mapped.

---

## Setup

```bash
cd /Users/ryanmckeeman/src/bizinsights/req_managed_agents/.claude/worktrees/otel-bridge
mix test --no-color 2>&1 | tail -3
```

**Expected:** `97 passed, 4 excluded` (or similar; 4 live-excluded tests is normal).

---

## A. iex smoke — SemConv

### A.1 `provider_name/0` returns "anthropic"

```bash
mix run -e 'IO.inspect ReqManagedAgents.OpenTelemetry.SemConv.provider_name()'
```

**Expected:**
```
"anthropic"
```

### A.2 `finish_reason/1` maps each terminal atom

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry.SemConv
results = Enum.map([:end_turn, :terminated, :error, :retries_exhausted], fn atom ->
  {atom, SemConv.finish_reason(atom)}
end)
IO.inspect results'
```

**Expected:**
```
[
  {:end_turn, "end_turn"},
  {:terminated, "terminated"},
  {:error, "error"},
  {:retries_exhausted, "retries_exhausted"}
]
```

### A.3 `finish_reason/1` unknown atom falls back to "terminated"

```bash
mix run -e 'IO.inspect ReqManagedAgents.OpenTelemetry.SemConv.finish_reason(:something_entirely_unknown)'
```

**Expected:**
```
"terminated"
```

---

## B. iex smoke — Attributes mappers

### B.1 `invoke_agent/1` — required gen_ai keys

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry.Attributes
out = Attributes.invoke_agent(%{session_id: "s_qa1"})
IO.inspect out'
```

**Expected:** a map containing all three keys:
```
%{
  "gen_ai.conversation.id" => "s_qa1",
  "gen_ai.operation.name" => "invoke_agent",
  "gen_ai.provider.name" => "anthropic"
}
```

### B.2 `chat/1` without usage — no usage keys present

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry.Attributes
out = Attributes.chat(%{session_id: "s_qa1"})
IO.inspect {out, Map.has_key?(out, "gen_ai.usage.input_tokens"), Map.has_key?(out, "gen_ai.usage.output_tokens")}'
```

**Expected:** the tuple's second and third elements are both `false`.

### B.3 `chat/1` with string-keyed Anthropic usage (realistic shape)

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry.Attributes
out = Attributes.chat(%{
  session_id: "s_qa1",
  usage: %{"input_tokens" => 10, "output_tokens" => 5}
})
IO.inspect {out["gen_ai.usage.input_tokens"], out["gen_ai.usage.output_tokens"]}'
```

**Expected:**
```
{10, 5}
```

### B.4 `chat/1` with atom-keyed usage

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry.Attributes
out = Attributes.chat(%{
  session_id: "s_qa1",
  usage: %{input_tokens: 20, output_tokens: 8}
})
IO.inspect {out["gen_ai.usage.input_tokens"], out["gen_ai.usage.output_tokens"]}'
```

**Expected:**
```
{20, 8}
```

### B.5 `tool/1` is_error false — no error.type key

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry.Attributes
out = Attributes.tool(%{session_id: "s_qa1", tool: "calculator", is_error: false})
IO.inspect {out["gen_ai.operation.name"], out["gen_ai.tool.name"], out["gen_ai.conversation.id"], Map.has_key?(out, "error.type")}'
```

**Expected:**
```
{"execute_tool", "calculator", "s_qa1", false}
```

### B.6 `tool/1` is_error true — error.type set

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry.Attributes
out = Attributes.tool(%{session_id: "s_qa1", tool: "search", is_error: true})
IO.inspect out["error.type"]'
```

**Expected:**
```
"tool_error"
```

### B.7 `terminal/1` maps each terminal atom to finish_reasons list

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry.Attributes
for atom <- [:end_turn, :terminated, :error, :retries_exhausted] do
  out = Attributes.terminal(%{session_id: "s_qa1", terminal: atom})
  IO.inspect {atom, out["gen_ai.response.finish_reasons"]}
end'
```

**Expected:**
```
{:end_turn, ["end_turn"]}
{:terminated, ["terminated"]}
{:error, ["error"]}
{:retries_exhausted, ["retries_exhausted"]}
```

### B.8 Privacy check — content-ish keys do NOT leak from `tool/1`

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry.Attributes
meta = %{
  session_id: "s1", tool: "search", is_error: false,
  input: "secret query", content: "secret content", result: "secret result"
}
out = Attributes.tool(meta)
IO.inspect {
  Map.has_key?(out, "input"),
  Map.has_key?(out, "content"),
  Map.has_key?(out, "result"),
  Map.keys(out) |> Enum.sort()
}'
```

**Expected:** the first three elements of the tuple are all `false`. The keys list contains only `gen_ai.*` and `error.*` keys.

### B.9 Privacy check — content-ish keys do NOT leak from `chat/1`

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry.Attributes
meta = %{
  session_id: "s1",
  usage: %{"input_tokens" => 5, "output_tokens" => 2},
  input: "secret prompt", content: "secret body", result: "secret answer"
}
out = Attributes.chat(meta)
IO.inspect {
  Map.has_key?(out, "input"),
  Map.has_key?(out, "content"),
  Map.has_key?(out, "result"),
  Map.keys(out) |> Enum.sort()
}'
```

**Expected:** the first three elements of the tuple are all `false`.

---

## C. iex smoke — `attributes_for/2` dispatch

### C.1 Stream event with atom-keyed `type: "agent.custom_tool_use"` → `{"tool_use", _}`

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry, as: OTel
{type, attrs} = OTel.attributes_for(
  [:req_managed_agents, :stream, :event],
  %{session_id: "s1", type: "agent.custom_tool_use"}
)
IO.inspect {type, attrs["gen_ai.provider.name"]}'
```

**Expected:**
```
{"tool_use", "anthropic"}
```

### C.2 Stream event with string-keyed `"type" => "agent.custom_tool_use"` → `{"tool_use", _}`

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry, as: OTel
{type, _} = OTel.attributes_for(
  [:req_managed_agents, :stream, :event],
  %{"session_id" => "s1", "type" => "agent.custom_tool_use"}
)
IO.inspect type'
```

**Expected:**
```
"tool_use"
```

### C.3 Stream event without tool_use type → `{"chat", _}`

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry, as: OTel
{type, attrs} = OTel.attributes_for(
  [:req_managed_agents, :stream, :event],
  %{session_id: "s1", type: "message_delta"}
)
IO.inspect {type, attrs["gen_ai.operation.name"]}'
```

**Expected:**
```
{"chat", "chat"}
```

### C.4 `[:req_managed_agents, :tool, :stop]` → `{"tool_result", _}`

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry, as: OTel
{type, attrs} = OTel.attributes_for(
  [:req_managed_agents, :tool, :stop],
  %{session_id: "s1", tool: "calculator", is_error: false}
)
IO.inspect {type, attrs["gen_ai.operation.name"]}'
```

**Expected:**
```
{"tool_result", "execute_tool"}
```

### C.5 `[:req_managed_agents, :session, :terminal]` → `{"turn_complete", _}`

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry, as: OTel
{type, attrs} = OTel.attributes_for(
  [:req_managed_agents, :session, :terminal],
  %{session_id: "s1", terminal: :end_turn}
)
IO.inspect {type, attrs["gen_ai.response.finish_reasons"]}'
```

**Expected:**
```
{"turn_complete", ["end_turn"]}
```

---

## D. Integration via real telemetry

Attaches a TEST handler via `:telemetry.attach_many` that calls `attributes_for/2` and stores results. Then drives all four RMA event names via `:telemetry.execute` with realistic metadata including `mimir_request_id`. Confirms each handler invocation produces the correct `{type, attrs}` and that `mimir_request_id` is reachable from the raw metadata (correlation passthrough).

### D.1 Full integration run — all four events + correlation passthrough

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry, as: OTel
{:ok, collector} = Agent.start_link(fn -> [] end)

:telemetry.attach_many(
  "qa-otel-integration",
  OTel.events(),
  fn event, _meas, meta, _ ->
    result = OTel.attributes_for(event, meta)
    Agent.update(collector, &[{event, result, meta} | &1])
  end,
  nil
)

mimir_request_id = "mim_req_abc123"

# 1. Chat stream event
:telemetry.execute(
  [:req_managed_agents, :stream, :event],
  %{},
  %{
    session_id: "s_integ1",
    type: "message_delta",
    usage: %{"input_tokens" => 15, "output_tokens" => 7},
    mimir_request_id: mimir_request_id
  }
)

# 2. Tool-use stream event
:telemetry.execute(
  [:req_managed_agents, :stream, :event],
  %{},
  %{
    session_id: "s_integ1",
    type: "agent.custom_tool_use",
    tool: "search",
    mimir_request_id: mimir_request_id
  }
)

# 3. Tool stop event
:telemetry.execute(
  [:req_managed_agents, :tool, :stop],
  %{duration: 150},
  %{
    session_id: "s_integ1",
    tool: "search",
    is_error: false,
    mimir_request_id: mimir_request_id
  }
)

# 4. Session terminal event
:telemetry.execute(
  [:req_managed_agents, :session, :terminal],
  %{},
  %{
    session_id: "s_integ1",
    terminal: :end_turn,
    mimir_request_id: mimir_request_id
  }
)

:telemetry.detach("qa-otel-integration")

results = Agent.get(collector, & &1) |> Enum.reverse()
IO.puts "Collected #{length(results)} events\n"

Enum.each(results, fn {event, {type, attrs}, meta} ->
  IO.puts "Event: #{inspect Enum.take(event, 3)}"
  IO.puts "  type: #{type}"
  IO.puts "  mimir_request_id passthrough: #{meta[:mimir_request_id] == mimir_request_id}"
  IO.puts "  gen_ai.provider.name: #{attrs["gen_ai.provider.name"]}"
  IO.puts "  gen_ai.conversation.id: #{attrs["gen_ai.conversation.id"]}"
  IO.puts ""
end)'
```

**Expected:**
- `Collected 4 events`
- Event 1: `type: "chat"`, mimir_request_id passthrough: `true`
- Event 2: `type: "tool_use"`, mimir_request_id passthrough: `true`
- Event 3: `type: "tool_result"`, mimir_request_id passthrough: `true`
- Event 4: `type: "turn_complete"`, mimir_request_id passthrough: `true`
- All four events: `gen_ai.provider.name: anthropic`, `gen_ai.conversation.id: s_integ1`

### D.2 String-keyed type dispatch via real telemetry

```bash
mix run -e '
alias ReqManagedAgents.OpenTelemetry, as: OTel
{:ok, collector} = Agent.start_link(fn -> [] end)

:telemetry.attach_many(
  "qa-otel-string-key",
  [[:req_managed_agents, :stream, :event]],
  fn event, _meas, meta, _ ->
    result = OTel.attributes_for(event, meta)
    Agent.update(collector, &[result | &1])
  end,
  nil
)

:telemetry.execute(
  [:req_managed_agents, :stream, :event],
  %{},
  %{"session_id" => "s_sk1", "type" => "agent.custom_tool_use", "mimir_request_id" => "mim_req_sk1"}
)

:telemetry.detach("qa-otel-string-key")

[{type, attrs}] = Agent.get(collector, & &1)
IO.inspect {type, attrs["gen_ai.conversation.id"]}'
```

**Expected:**
```
{"tool_use", "s_sk1"}
```

---

## E. attach / available lifecycle

### E.1 `available?/0` matches `Code.ensure_loaded?(:otel_tracer)`

```bash
mix run -e '
a = ReqManagedAgents.OpenTelemetry.available?()
b = Code.ensure_loaded?(:otel_tracer)
IO.inspect {a, b, a == b}'
```

**Expected:**
```
{false, false, true}
```

(Both `false` in this env; the equality check confirms they agree.)

### E.2 `attach/1` returns `{:error, :opentelemetry_unavailable}` when OTel not loaded

```bash
mix run -e 'IO.inspect ReqManagedAgents.OpenTelemetry.attach("qa-e2-handler")'
```

**Expected:**
```
{:error, :opentelemetry_unavailable}
```

### E.3 `attach/1` called twice with same ID does not raise

```bash
mix run -e '
r1 = ReqManagedAgents.OpenTelemetry.attach("qa-e3-double")
r2 = ReqManagedAgents.OpenTelemetry.attach("qa-e3-double")
IO.inspect {r1, r2}'
```

**Expected:** both calls return the same error tuple; no exception raised.
```
{{:error, :opentelemetry_unavailable}, {:error, :opentelemetry_unavailable}}
```

### E.4 `detach/1` is safe when handler was never attached

```bash
mix run -e 'IO.inspect ReqManagedAgents.OpenTelemetry.detach("qa-never-attached-xyz")'
```

**Expected:**
```
{:error, :not_found}
```

> `detach/1` delegates to `:telemetry.detach/1`, which returns `{:error, :not_found}` for an
> unregistered handler ID — the documented idiomatic contract. The call is **safe** (it does not
> raise); only the return value is an error tuple, not `:ok`. (QA F-1: the `detach/1` `@spec` was
> widened to `:: :ok | {:error, :not_found}` to match.)

---

## K. Checklist

| #   | Check | Status |
|-----|-------|--------|
| K1  | `SemConv.provider_name/0` == "anthropic" | ☐ |
| K2  | `SemConv.finish_reason/1` maps all four terminal atoms correctly | ☐ |
| K3  | `SemConv.finish_reason/1` unknown atom falls back to "terminated" | ☐ |
| K4  | `Attributes.invoke_agent/1` emits `gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.conversation.id` | ☐ |
| K5  | `Attributes.chat/1` without usage: no `gen_ai.usage.*` keys in output | ☐ |
| K6  | `Attributes.chat/1` with string-keyed Anthropic usage: tokens present | ☐ |
| K7  | `Attributes.chat/1` with atom-keyed usage: tokens present | ☐ |
| K8  | `Attributes.tool/1` is_error false: no `error.type` key | ☐ |
| K9  | `Attributes.tool/1` is_error true: `error.type == "tool_error"` | ☐ |
| K10 | `Attributes.terminal/1` produces correct `gen_ai.response.finish_reasons` list for all four atoms | ☐ |
| K11 | Privacy: `tool/1` with `input`/`content`/`result` in metadata — none leak into output | ☐ |
| K12 | Privacy: `chat/1` with `input`/`content`/`result` in metadata — none leak into output | ☐ |
| K13 | `attributes_for/2` stream event with atom-keyed `type: "agent.custom_tool_use"` → `{"tool_use", _}` | ☐ |
| K14 | `attributes_for/2` stream event with string-keyed `"type" => "agent.custom_tool_use"` → `{"tool_use", _}` | ☐ |
| K15 | `attributes_for/2` stream event without tool_use type → `{"chat", _}` | ☐ |
| K16 | `attributes_for/2` `[:req_managed_agents, :tool, :stop]` → `{"tool_result", _}` | ☐ |
| K17 | `attributes_for/2` `[:req_managed_agents, :session, :terminal]` → `{"turn_complete", _}` | ☐ |
| K18 | Integration: 4 `:telemetry.execute` calls each invoke the handler and produce correct `{type, attrs}` | ☐ |
| K19 | Integration: `mimir_request_id` is accessible from raw metadata in the handler (correlation passthrough) | ☐ |
| K20 | Integration: string-keyed `"type"` dispatch works via real telemetry | ☐ |
| K21 | `available?/0 == Code.ensure_loaded?(:otel_tracer)` (false in this env) | ☐ |
| K22 | `attach/1` returns `{:error, :opentelemetry_unavailable}` when OTel not loaded | ☐ |
| K23 | `attach/1` called twice with same ID does not raise | ☐ |
| K24 | `detach/1` is safe on an unregistered handler ID | ☐ |
