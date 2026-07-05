# RMA 0.6.0 — Providers.Local + Carry-Ins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An in-process `ReqManagedAgents.Providers.Local` — the third `Provider`, running the agent loop client-side over a pluggable `chat_fun` — plus the two MIM-75 carry-ins (api_key threading, metadata passthrough) and the README repositioning ("one Session loop, any loop host").

**Architecture:** Local is `:request_response`: `poll_turn/2` makes ONE model call per turn through `chat_fun`, a function over a **neutral OpenAI-chat-completions-shaped wire contract** (plain string-keyed maps). The conn holds the growing message history. The default chat_fun adapts the neutral wire to `ReqLLM.generate_text/3` (`req_llm` is an optional dep with raise-at-first-use, mirroring `AgentCore.Deps`); a mimir-lane chat_fun is a bare `Req.post` to `/v1/chat/completions` with a granted key — no adaptation. The loop guards relocate from biai's `Core.Runner` (they exist for weak-instruction-following local models): duplicate-call dedup, consecutive-error correctives, final-turn directive, transient-error retry. Events are synthesized under the `local.*` namespace so `SessionResult.events` stays raw-preserving.

**Tech Stack:** Elixir ~> 1.16, `{:req_llm, "~> 1.10", optional: true}`, Req (existing dep), ExUnit. Ollama for the one `:external` live test.

**Spec:** `docs/superpowers/specs/2026-07-04-mim79-consolidation-architecture-design.md` §4 (0.6.0 row). Binding prior art: `mimir-gateway` `docs/planning/2026-07-04-rma-local-provider-and-session-gaps.md` §2–§3 (callback table, guards list, routing note, README premise). Requires 0.5.0 underneath (terminal re-prompt + `text_delta` + `turn_guard` ship there).

## Global Constraints

- **Version control is jj, not git.** Commit with `jj describe -m "<message>" && jj new`. Never `git add/commit/push`.
- **Public-repo hygiene:** internal tracker identifiers (`MIM-…`) never appear in commit messages, code, comments, test names, moduledocs, README, CHANGELOG, or PR titles. The ONLY permitted tracker reference is the PR body's trailing `Closes MIM-…` line.
- **RMA never depends on `mimir`** — no pricing tables, no virtual-key concepts, no mimir types. Governance reaches Local through `model_config` (granted key + routed base_url) and the 0.5.0 `turn_guard`/`handle_event` hooks only.
- **`req_llm` is optional** (`optional: true`), gated by raise-at-first-use (`Local.Deps.ensure!/0`, mirroring `ReqManagedAgents.AgentCore.Deps`). Only the default chat_fun touches it; injected chat_funs must work with req_llm absent.
- **Neutral chat wire contract (frozen by this release):** `chat_fun.(request :: map()) :: {:ok, response :: map()} | {:error, term()}` where request/response are OpenAI-chat-completions-shaped plain maps (exact shapes in Task 3). This is what makes "point chat_fun at a mimir lane" a bare HTTP POST.
- **Raw preservation:** synthesized events use the `local.*` type namespace; `normalize/1` derives from them additively.
- **Directive wording relocates from biai's `Core.Runner.Directives` verbatim** where possible (eval-gate continuity for SP7); `final_turn` is generalized to name the spec's `terminal_tool` instead of biai's hardcoded "(e.g. emit_narrative)" example.
- **Transient-retry semantics preserved (biai parity):** transient = HTTP 408/≥500 or transport `:timeout | :closed | :econnrefused | :econnreset | :connect_timeout`; exponential backoff `backoff_ms * 2^n`; defaults `max_retries: 3`, `backoff_ms: 1000`; injectable `sleep_fun`.
- Canonical `model_config` keys (atom): `:model`, `:api_key`, `:base_url`, `:metadata`.
- Release discipline: version `0.6.0` (bump from `0.5.0`), dated CHANGELOG entry. Full suite green: `mix test` (`:external` excluded by default).

---

### Task 1: `Local.Deps` — optional `req_llm` with raise-at-first-use

**Files:**
- Modify: `mix.exs` (deps)
- Create: `lib/req_managed_agents/local/deps.ex`
- Test: `test/req_managed_agents/local/deps_test.exs`

**Interfaces:**
- Produces: `ReqManagedAgents.Local.Deps.ensure!() :: :ok` (raises with an actionable message when `ReqLLM` is not loaded). Task 4's `ReqLLMChat` calls it at chat_fun construction.

- [ ] **Step 1: Add the optional dep**

In `mix.exs` `deps/0`, after the AWS optional deps:

```elixir
      # req_llm is optional: only the Local provider's DEFAULT chat_fun needs it.
      # Injected chat_funs (tests, Ollama, mimir lanes) work without it;
      # Local raises a clear error at first use if it's missing (Local.Deps).
      {:req_llm, "~> 1.10", optional: true},
```

Run: `mix deps.get`
Expected: resolves req_llm (present for RMA's own dev/test; optional only affects downstream consumers).

- [ ] **Step 2: Write the failing test**

Create `test/req_managed_agents/local/deps_test.exs`:

```elixir
defmodule ReqManagedAgents.Local.DepsTest do
  use ExUnit.Case, async: true

  test "ensure!/0 is :ok when req_llm is present (it is, in this repo's test env)" do
    assert ReqManagedAgents.Local.Deps.ensure!() == :ok
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `mix test test/req_managed_agents/local/deps_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 4: Implement (mirror `AgentCore.Deps`)**

Create `lib/req_managed_agents/local/deps.ex`:

```elixir
defmodule ReqManagedAgents.Local.Deps do
  @moduledoc false

  # req_llm is `optional: true` in mix.exs so consumers that inject their own
  # chat_fun (tests, Ollama, mimir lanes) don't pull it. Only the default
  # ReqLLM-backed chat_fun needs it, so ReqLLMChat calls `ensure!/0` and raises
  # this actionable error instead of an UndefinedFunctionError.

  @spec ensure!() :: :ok
  def ensure! do
    if Code.ensure_loaded?(ReqLLM) do
      :ok
    else
      raise """
      the Local provider's default chat_fun requires the optional req_llm \
      dependency, which is not present in this project.

      Either add it to your mix.exs deps:

            {:req_llm, "~> 1.10"},

      or inject your own chat_fun (see ReqManagedAgents.Providers.Local — a \
      chat_fun over any OpenAI-compatible endpoint is a plain Req.post).
      """
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes, then commit**

Run: `mix test test/req_managed_agents/local/deps_test.exs`
Expected: PASS.

```bash
jj describe -m "feat(local): optional req_llm dep + Local.Deps raise-at-first-use" && jj new
```

---

### Task 2: `Local.Retry` — transient-error retry around the chat call

**Files:**
- Create: `lib/req_managed_agents/local/retry.ex`
- Test: `test/req_managed_agents/local/retry_test.exs`

**Interfaces:**
- Produces: `ReqManagedAgents.Local.Retry` — `wrap(chat_fun, %Retry{}) :: (map() -> {:ok, map()} | {:error, term()})` and `transient?/1`. Struct fields: `max_retries: 3, backoff_ms: 1000, sleep_fun: &Process.sleep/1`. Task 3's `open/2` wraps the chat_fun with it.

- [ ] **Step 1: Write the failing tests**

Create `test/req_managed_agents/local/retry_test.exs`:

```elixir
defmodule ReqManagedAgents.Local.RetryTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Local.Retry

  defp flaky(fails, reason, agent) do
    fn _request ->
      n = Agent.get_and_update(agent, &{&1, &1 + 1})
      if n < fails, do: {:error, reason}, else: {:ok, %{"ok" => n}}
    end
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    {:ok, agent: agent}
  end

  test "retries transient errors with exponential backoff", %{agent: agent} do
    test = self()
    cfg = %Retry{max_retries: 3, backoff_ms: 100, sleep_fun: &send(test, {:slept, &1})}

    wrapped = Retry.wrap(flaky(2, %{status: 503}, agent), cfg)
    assert {:ok, %{"ok" => 2}} = wrapped.(%{})
    assert_received {:slept, 100}
    assert_received {:slept, 200}
  end

  test "exhausted retries surface the error", %{agent: agent} do
    cfg = %Retry{max_retries: 1, backoff_ms: 1, sleep_fun: fn _ -> :ok end}
    wrapped = Retry.wrap(flaky(5, %{reason: :timeout}, agent), cfg)
    assert {:error, %{reason: :timeout}} = wrapped.(%{})
  end

  test "non-transient errors do not retry", %{agent: agent} do
    cfg = %Retry{max_retries: 3, backoff_ms: 1, sleep_fun: fn _ -> flunk("slept") end}
    wrapped = Retry.wrap(flaky(5, %{status: 401}, agent), cfg)
    assert {:error, %{status: 401}} = wrapped.(%{})
    assert Agent.get(agent, & &1) == 1
  end

  test "transient?/1 classification: 408/5xx + transport errors" do
    assert Retry.transient?(%{status: 408})
    assert Retry.transient?(%{status: 500})
    assert Retry.transient?(%{status: 503})
    refute Retry.transient?(%{status: 429})
    refute Retry.transient?(%{status: 404})
    assert Retry.transient?(%{reason: :timeout})
    assert Retry.transient?(%{reason: :econnrefused})
    assert Retry.transient?(%{cause: :closed})
    refute Retry.transient?(:weird)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/req_managed_agents/local/retry_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement (port of biai `Core.Runner.Retry`, arity adapted to the neutral chat_fun)**

Create `lib/req_managed_agents/local/retry.ex`:

```elixir
defmodule ReqManagedAgents.Local.Retry do
  @moduledoc false
  # Transient-error retry for the chat_fun (HTTP 408/≥500 + transport; exponential
  # backoff). Relocated from biai-managed-agents Core.Runner.Retry.
  require Logger
  defstruct max_retries: 3, backoff_ms: 1000, sleep_fun: &Process.sleep/1

  @type t :: %__MODULE__{
          max_retries: non_neg_integer(),
          backoff_ms: pos_integer(),
          sleep_fun: (non_neg_integer() -> any())
        }

  @transient_transport [:timeout, :closed, :econnrefused, :econnreset, :connect_timeout]

  @doc "Wrap a chat_fun so transient failures retry; returns a fn with the same (request) shape."
  @spec wrap((map() -> {:ok, map()} | {:error, term()}), t()) ::
          (map() -> {:ok, map()} | {:error, term()})
  def wrap(chat_fun, %__MODULE__{} = cfg) do
    fn request -> attempt(chat_fun, request, cfg, 0) end
  end

  defp attempt(chat_fun, request, cfg, n) do
    case chat_fun.(request) do
      {:error, reason} = err ->
        if n < cfg.max_retries and transient?(reason) do
          delay = cfg.backoff_ms * Integer.pow(2, n)

          Logger.warning(
            "[ReqManagedAgents.Providers.Local] transient chat error (#{describe(reason)}); " <>
              "retry #{n + 1}/#{cfg.max_retries} after #{delay}ms"
          )

          cfg.sleep_fun.(delay)
          attempt(chat_fun, request, cfg, n + 1)
        else
          err
        end

      other ->
        other
    end
  end

  @doc false
  def transient?(%{status: s}) when is_integer(s), do: s == 408 or s >= 500
  def transient?(%{reason: r}) when r in @transient_transport, do: true
  def transient?(%{cause: c}) when is_atom(c) and c in @transient_transport, do: true
  def transient?(_), do: false

  defp describe(%{status: s}) when is_integer(s), do: "status=#{s}"
  defp describe(r), do: inspect(r) |> String.slice(0, 80)
end
```

- [ ] **Step 4: Run tests to verify they pass, then commit**

Run: `mix test test/req_managed_agents/local/retry_test.exs`
Expected: PASS.

```bash
jj describe -m "feat(local): Local.Retry — transient-error retry with backoff, neutral chat_fun arity" && jj new
```

---

### Task 3: `Providers.Local` — core callbacks, one model call per turn

**Files:**
- Create: `lib/req_managed_agents/providers/local.ex`, `lib/req_managed_agents/local/directives.ex`
- Test: `test/req_managed_agents/providers/local_test.exs`

**Interfaces:**
- Consumes: `Local.Retry` (Task 2), `Local.Deps` + `ReqLLMChat` (Tasks 1/4 — only via the `chat_fun` default, injected in every test here), `Provider` behaviour incl. 0.5.0's optional `text_delta/1`.
- Produces: `ReqManagedAgents.Providers.Local` implementing `mode/0 = :request_response`, `open/2`, `kickoff_input/1`, `user_input/1`, `resume_input/2`, `poll_turn/2`, `normalize/1`, `provision/2` (identity), `teardown/2` (no-op), `text_delta/1`, `supports_outcomes?` absent (unsupported). **Neutral wire contract** (frozen):

```
request  :: %{model: term(), messages: [message], tools: [tool]}
message  :: %{"role" => "system"|"user"|"assistant"|"tool", "content" => String.t() | nil}
          | assistant + "tool_calls" => [%{"id" => id, "type" => "function",
              "function" => %{"name" => name, "arguments" => json_string}}]
          | %{"role" => "tool", "tool_call_id" => id, "content" => String.t()}
tool     :: %{"type" => "function", "function" => %{"name" =>, "description" =>, "parameters" => json_schema}}
response :: %{"choices" => [%{"message" => assistant_message, "finish_reason" => "stop"|"tool_calls"|"length"}],
              "usage" => %{"prompt_tokens" => n, "completion_tokens" => n}}
```

Spec tools arrive Anthropic-shaped (`%{"name" =>, "description" =>, "input_schema" =>}` — same shape the CMA provider provisions) and are converted to the `tool` shape above. Guards land in Task 5; this task is the happy path.

- [ ] **Step 1: Write the failing tests**

Create `test/req_managed_agents/providers/local_test.exs`:

```elixir
defmodule ReqManagedAgents.Providers.LocalTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Providers.Local
  alias ReqManagedAgents.{ToolResult, ToolUse, TurnResult, Usage}

  @spec_map %{
    system_prompt: "You are terse.",
    tools: [
      %{"name" => "lookup", "description" => "Look up", "input_schema" => %{"type" => "object"}}
    ],
    terminal_tool: nil,
    model_config: %{model: "test:model"}
  }

  defp scripted(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn request ->
      fun = Agent.get_and_update(agent, fn [r | rest] -> {r, rest} end)
      fun.(request)
    end
  end

  # A response fun gets the request (for assertions) and returns {:ok, response}.
  defp text_response(text) do
    fn _req ->
      {:ok,
       %{
         "choices" => [
           %{"message" => %{"role" => "assistant", "content" => text}, "finish_reason" => "stop"}
         ],
         "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
       }}
    end
  end

  defp tool_call_response(id, name, args_json) do
    fn _req ->
      {:ok,
       %{
         "choices" => [
           %{
             "message" => %{
               "role" => "assistant",
               "content" => nil,
               "tool_calls" => [
                 %{
                   "id" => id,
                   "type" => "function",
                   "function" => %{"name" => name, "arguments" => args_json}
                 }
               ]
             },
             "finish_reason" => "tool_calls"
           }
         ],
         "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 8}
       }}
    end
  end

  defp open!(chat_fun, extra \\ []) do
    {:ok, conn} =
      Local.open([spec: @spec_map, chat_fun: chat_fun, prompt: "hi"] ++ extra, self())

    conn
  end

  test "open/2 builds the conn: system prompt, converted tools, minted session_id" do
    conn = open!(fn _ -> {:ok, %{}} end)

    assert [%{"role" => "system", "content" => "You are terse."}] = conn.history
    assert [%{"type" => "function", "function" => %{"name" => "lookup"}}] = conn.tools
    assert "local_" <> _ = conn.session_id
  end

  test "poll_turn: kickoff appends the user message and returns local.model_response events" do
    test = self()

    chat_fun = fn request ->
      send(test, {:chat_request, request})
      text_response("hello").(request)
    end

    conn = open!(chat_fun)

    assert {:ok, events, conn2} = Local.poll_turn(conn, Local.kickoff_input(prompt: "hi"))

    assert_received {:chat_request, %{model: "test:model", messages: messages, tools: [_]}}
    assert [%{"role" => "system"}, %{"role" => "user", "content" => "hi"}] = messages

    assert [%{"type" => "local.model_response", "finish_reason" => "stop"} = ev] = events
    assert ev["message"]["content"] == "hello"

    # history grew: system, user, assistant
    assert [_, _, %{"role" => "assistant", "content" => "hello"}] = conn2.history
  end

  test "normalize: stop → :end_turn with text and usage" do
    conn = open!(scripted([text_response("done!")]))
    {:ok, events, _} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))

    assert %TurnResult{
             terminal: :end_turn,
             stop_reason: "stop",
             text: "done!",
             custom_tool_uses: [],
             usage: %Usage{input_tokens: 10, output_tokens: 5, raw: [_]},
             events: ^events
           } = Local.normalize(events)
  end

  test "normalize: tool_calls → :requires_action with decoded ToolUse" do
    conn = open!(scripted([tool_call_response("c1", "lookup", ~s({"q":"x"}))]))
    {:ok, events, _} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))

    assert %TurnResult{
             terminal: :requires_action,
             custom_tool_uses: [%ToolUse{id: "c1", name: "lookup", input: %{"q" => "x"}}]
           } = Local.normalize(events)
  end

  test "resume appends tool results then calls the model again" do
    test = self()

    second = fn request ->
      send(test, {:second_request, request})
      text_response("after tools").(request)
    end

    conn = open!(scripted([tool_call_response("c1", "lookup", "{}"), second]))
    {:ok, _events, conn} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))

    uses = [%ToolUse{id: "c1", name: "lookup", input: %{}}]
    results = [%ToolResult{tool_use_id: "c1", text: "found it", is_error: false}]

    assert {:ok, events, _conn} = Local.poll_turn(conn, Local.resume_input(uses, results))

    assert_received {:second_request, %{messages: messages}}

    assert %{"role" => "tool", "tool_call_id" => "c1", "content" => "found it"} =
             Enum.find(messages, &(&1["role"] == "tool"))

    assert [%{"type" => "local.model_response"}] = events
  end

  test "error tool results are JSON-tagged" do
    test = self()

    second = fn request ->
      send(test, {:second_request, request})
      text_response("ok").(request)
    end

    conn = open!(scripted([tool_call_response("c1", "lookup", "{}"), second]))
    {:ok, _, conn} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))

    uses = [%ToolUse{id: "c1", name: "lookup", input: %{}}]
    results = [%ToolResult{tool_use_id: "c1", text: "boom", is_error: true}]
    {:ok, _, _} = Local.poll_turn(conn, Local.resume_input(uses, results))

    assert_received {:second_request, %{messages: messages}}
    tool_msg = Enum.find(messages, &(&1["role"] == "tool"))
    assert Jason.decode!(tool_msg["content"]) == %{"error" => "boom", "isError" => true}
  end

  test "chat_fun error surfaces as {:error, reason}" do
    conn = open!(fn _ -> {:error, %{status: 401}} end)
    assert {:error, %{status: 401}} = Local.poll_turn(conn, Local.kickoff_input(prompt: "x"))
  end

  test "finish_reason length → :terminated" do
    resp = fn _req ->
      {:ok,
       %{
         "choices" => [
           %{"message" => %{"role" => "assistant", "content" => "trunc"}, "finish_reason" => "length"}
         ],
         "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
       }}
    end

    conn = open!(scripted([resp]))
    {:ok, events, _} = Local.poll_turn(conn, Local.kickoff_input(prompt: "x"))
    assert %TurnResult{terminal: :terminated, stop_reason: "length"} = Local.normalize(events)
  end

  test "provision/teardown: identity handle, nothing server-side" do
    assert {:ok, @spec_map} = Local.provision(@spec_map, [])
    assert :ok = Local.teardown(@spec_map, [])
  end

  test "text_delta/1 maps local.model_response content" do
    ev = %{"type" => "local.model_response", "message" => %{"content" => "chunk"}}
    assert Local.text_delta(ev) == "chunk"
    assert Local.text_delta(%{"type" => "local.model_response", "message" => %{"content" => nil}}) == nil
    assert Local.text_delta(%{"type" => "other"}) == nil
  end

  test "outcome kickoff is unsupported (Session gate)" do
    assert {:error, :outcome_unsupported} =
             ReqManagedAgents.Session.run(Local,
               handler: fn _, _, _ -> {:ok, ""} end,
               spec: @spec_map,
               chat_fun: fn _ -> {:ok, %{}} end,
               outcome: %{description: "d", rubric: "r"}
             )
  end
end
```

Note: in this file, scripted entries are 1-arity funs (they receive the request and return the chat result) — `scripted/1` pops the next fun and applies it. Plain `text_response/1`-style helpers already return funs, so both `scripted([text_response("x")])` and `scripted([fn req -> ... end])` work.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/req_managed_agents/providers/local_test.exs`
Expected: FAIL — `ReqManagedAgents.Providers.Local` undefined.

- [ ] **Step 3: Create the directives module**

Create `lib/req_managed_agents/local/directives.ex` (wording relocated from biai `Core.Runner.Directives`; `final_turn/1` generalized to the spec's terminal tool):

```elixir
defmodule ReqManagedAgents.Local.Directives do
  @moduledoc false
  # Loop directives injected into the conversation for weak-instruction-following
  # local models. Wording relocated verbatim from biai-managed-agents
  # Core.Runner.Directives (eval-gate continuity), except final_turn/1 which
  # names the spec's terminal_tool instead of biai's hardcoded example.

  def duplicate_tool,
    do:
      "You already called this tool with these exact arguments; the result is unchanged. " <>
        "Do NOT repeat it. If you have enough information, call your terminal tool now."

  def final_turn(nil),
    do:
      "FINAL TURN: you are about to reach the maximum number of turns. You MUST produce " <>
        "your final answer now with the information you have already gathered. Do not " <>
        "call any other tool."

  def final_turn(terminal_tool),
    do:
      "FINAL TURN: you are about to reach the maximum number of turns. You MUST call " <>
        "your terminal tool (#{terminal_tool}) now with the information you have already " <>
        "gathered. Do not call any other tool."

  def corrective(name, err),
    do:
      "STOP — the #{name} tool rejected your input again: #{err}. You must change your input to " <>
        "fix THIS specific error before calling #{name} again (or call your terminal tool)."
end
```

- [ ] **Step 4: Implement `Providers.Local` (happy path)**

Create `lib/req_managed_agents/providers/local.ex`:

```elixir
defmodule ReqManagedAgents.Providers.Local do
  @moduledoc """
  `ReqManagedAgents.Provider` that runs the agent loop **in-process** — `:request_response`
  mode, one model call per `poll_turn/2` through a pluggable `chat_fun`.

  The chat wire contract is neutral, OpenAI-chat-completions-shaped, plain string-keyed
  maps: `chat_fun.(%{model:, messages:, tools:}) :: {:ok, response} | {:error, reason}`.
  The default chat_fun adapts it to `ReqLLM.generate_text/3` (optional `req_llm` dep);
  pointing a chat_fun at any OpenAI-compatible endpoint is a bare `Req.post` — e.g. a
  mimir lane (`/v1/chat/completions` + granted key via `model_config`) for hard
  data-plane budget enforcement.

  Open opts: `:spec` (the `t:ReqManagedAgents.Provider.spec/0`, also the `provision/2`
  identity handle), `:model_config` (canonical keys `:model`, `:api_key`, `:base_url`,
  `:metadata`; defaults from `spec.model_config`), `:chat_fun`, `:max_turns`,
  `:session_id`, retry tuning (`:max_chat_retries`, `:retry_backoff_ms`, `:sleep_fun`).

  Events are synthesized under the `local.*` namespace (`local.model_response`, and the
  guard events added by the loop guards) so `SessionResult.events` stays raw-preserving.
  """
  @behaviour ReqManagedAgents.Provider

  alias ReqManagedAgents.Local.{Deps, Directives, Retry}
  alias ReqManagedAgents.{ToolUse, TurnResult, Usage}

  # The conn is a struct, not a bag of keys: one place to see everything a turn needs.
  defstruct history: [],
            tools: [],
            terminal_tool: nil,
            chat_fun: nil,
            model: nil,
            session_id: nil,
            max_turns: 50,
            polls: 0,
            seen: MapSet.new(),
            error_counts: %{}

  @type t :: %__MODULE__{
          history: [map()],
          tools: [map()],
          terminal_tool: String.t() | nil,
          chat_fun: (map() -> {:ok, map()} | {:error, term()}),
          model: term(),
          session_id: String.t(),
          max_turns: pos_integer(),
          polls: non_neg_integer(),
          seen: MapSet.t(),
          error_counts: %{optional(String.t()) => non_neg_integer()}
        }

  @impl true
  def mode, do: :request_response

  @impl true
  def provision(spec, _opts), do: {:ok, spec}

  @impl true
  def teardown(_handle, _opts), do: :ok

  @impl true
  def open(opts, _subscriber) do
    spec = opts[:spec] || %{}
    model_config = normalize_model_config(opts[:model_config] || spec[:model_config])

    retry = %Retry{
      max_retries: opts[:max_chat_retries] || 3,
      backoff_ms: opts[:retry_backoff_ms] || 1000,
      sleep_fun: opts[:sleep_fun] || (&Process.sleep/1)
    }

    {:ok,
     %__MODULE__{
       history: system_history(spec[:system_prompt]),
       tools: Enum.map(spec[:tools] || [], &to_function_tool/1),
       terminal_tool: spec[:terminal_tool],
       chat_fun: Retry.wrap(opts[:chat_fun] || default_chat_fun(model_config), retry),
       model: model_config[:model],
       session_id: opts[:session_id] || mint_session_id(),
       max_turns: opts[:max_turns] || 50
     }}
  end

  defp normalize_model_config(nil), do: %{}
  defp normalize_model_config(%{} = config), do: config
  # A CMA-style spec carries a bare model term in model_config — lift it.
  defp normalize_model_config(model), do: %{model: model}

  defp mint_session_id,
    do: "local_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp default_chat_fun(model_config) do
    Deps.ensure!()
    ReqManagedAgents.Local.ReqLLMChat.chat_fun(model_config)
  end

  defp system_history(nil), do: []
  defp system_history(prompt), do: [%{"role" => "system", "content" => prompt}]

  # Spec tools arrive Anthropic-shaped (name/description/input_schema) — the same
  # string-keyed wire maps the CMA provider provisions. One shape, no dual-keying;
  # they go to the model OpenAI-function-shaped.
  defp to_function_tool(%{"name" => name} = tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => tool["description"] || "",
        "parameters" => tool["input_schema"] || %{"type" => "object"}
      }
    }
  end

  @impl true
  def kickoff_input(opts), do: {:messages, [%{"role" => "user", "content" => opts[:prompt] || "Begin."}]}

  @impl true
  def user_input(text), do: {:messages, [%{"role" => "user", "content" => text}]}

  @impl true
  def resume_input(tool_uses, results), do: {:resume, tool_uses, results}

  @impl true
  def poll_turn(conn, input) do
    {conn, injected_events} = apply_input(conn, input)
    conn = %{conn | polls: conn.polls + 1}

    case conn.chat_fun.(chat_request(conn)) do
      {:ok, response} -> accept_response(conn, injected_events, response)
      {:error, _reason} = error -> error
    end
  end

  defp chat_request(conn),
    do: %{model: conn.model, messages: conn.history, tools: conn.tools}

  defp accept_response(conn, injected_events, %{
         "choices" => [%{"message" => message, "finish_reason" => finish_reason} | _]
       } = response) do
    conn = %{conn | history: conn.history ++ [message]}

    event = %{
      "type" => "local.model_response",
      "message" => message,
      "finish_reason" => finish_reason,
      "usage" => response["usage"]
    }

    {:ok, injected_events ++ [event], conn}
  end

  defp accept_response(_conn, _injected_events, malformed),
    do: {:error, {:malformed_chat_response, malformed}}

  # ── input application (guards extend this in the loop-guards change) ─────────
  defp apply_input(conn, {:messages, messages}) do
    {%{conn | history: conn.history ++ messages}, []}
  end

  defp apply_input(conn, {:resume, tool_uses, results}) do
    by_id = Map.new(results, &{&1.tool_use_id, &1})

    tool_messages =
      Enum.map(tool_uses, fn use ->
        r = Map.fetch!(by_id, use.id)
        %{"role" => "tool", "tool_call_id" => use.id, "content" => result_content(r)}
      end)

    {%{conn | history: conn.history ++ tool_messages}, []}
  end

  defp result_content(%{is_error: true, text: text}),
    do: Jason.encode!(%{"error" => text, "isError" => true})

  defp result_content(%{text: text}), do: text

  # ── normalization ─────────────────────────────────────────────────────────────
  @impl true
  def normalize(events) do
    case Enum.find(events, &(&1["type"] == "local.model_response")) do
      nil ->
        %TurnResult{terminal: :terminated, stop_reason: nil, events: events}

      %{"message" => message, "finish_reason" => fr, "usage" => usage} ->
        tool_calls = message["tool_calls"] || []

        %TurnResult{
          terminal: terminal(fr, tool_calls),
          stop_reason: fr,
          text: message["content"] || "",
          custom_tool_uses: Enum.map(tool_calls, &to_tool_use/1),
          server_tool_uses: [],
          usage: to_usage(usage),
          events: events
        }
    end
  end

  defp to_tool_use(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}) do
    %ToolUse{id: id, name: name, input: decode_args(args)}
  end

  defp decode_args(args) when is_map(args), do: args

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, %{} = m} -> m
      _ -> %{}
    end
  end

  defp decode_args(_), do: %{}

  @doc false
  def terminal(_fr, [_ | _]), do: :requires_action
  def terminal("stop", _), do: :end_turn
  def terminal("tool_calls", _), do: :requires_action
  def terminal(_other, _), do: :terminated

  # The neutral contract names them prompt_tokens/completion_tokens — one shape,
  # no fallback key-chains. A response without usage yields nil (Session skips it).
  defp to_usage(%{"prompt_tokens" => input} = usage),
    do: %Usage{
      input_tokens: input,
      output_tokens: usage["completion_tokens"] || 0,
      raw: [usage]
    }

  defp to_usage(_), do: nil

  @impl true
  def text_delta(%{"type" => "local.model_response", "message" => %{"content" => c}})
      when is_binary(c) and c != "",
      do: c

  def text_delta(_), do: nil
end
```

Note the `terminal/2` ordering: a response carrying tool_calls is `:requires_action` regardless of `finish_reason` (some OpenAI-compatible servers report `"stop"` alongside tool_calls).

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/req_managed_agents/providers/local_test.exs`
Expected: all PASS except any depending on Task 4 (none here — every test injects `chat_fun`). The outcome test passes because Local does not export `supports_outcomes?/0` (the 0.5.0 Session gate rejects).

- [ ] **Step 6: Run the provider conformance suite**

Run: `mix test test/req_managed_agents/provider_conformance_test.exs`
Expected: PASS. Check what conformance asserts about providers; if it enumerates provider modules, add `ReqManagedAgents.Providers.Local` to its list and re-run.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(local): Providers.Local — in-process loop over a neutral chat_fun seam

:request_response provider: one model call per poll_turn through
chat_fun.(%{model:, messages:, tools:}) — OpenAI-chat-completions-shaped
plain maps, so a mimir-lane chat_fun is a bare Req.post. local.* event
namespace keeps SessionResult.events raw-preserving. provision/2 is
identity (nothing server-side)." && jj new
```

---

### Task 4: Loop guards — dedup short-circuit, correctives, final-turn directive

**Files:**
- Modify: `lib/req_managed_agents/providers/local.ex`
- Test: `test/req_managed_agents/providers/local_guards_test.exs` (create)

**Interfaces:**
- Consumes: Task 3's conn fields `seen`, `error_counts`, `polls`, `max_turns`, `terminal_tool`; `Local.Directives`.
- Produces: guard semantics relocated from biai `Core.Runner` — (a) a repeated `{name, input}` tool call is never surfaced to the Session; the provider self-answers it with the duplicate directive; (b) a tool that errors twice consecutively gets a corrective user directive injected before the next model call; (c) the last allowed turn gets the final-turn directive injected. New synthesized events: `local.duplicate_tool_call`, `local.directive`.

- [ ] **Step 1: Write the failing tests**

Create `test/req_managed_agents/providers/local_guards_test.exs`:

```elixir
defmodule ReqManagedAgents.Providers.LocalGuardsTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Providers.Local
  alias ReqManagedAgents.Local.Directives
  alias ReqManagedAgents.{ToolResult, ToolUse, TurnResult}

  @spec_map %{
    system_prompt: "sys",
    tools: [%{"name" => "lookup", "description" => "", "input_schema" => %{}}],
    terminal_tool: "submit",
    model_config: %{model: "test:model"}
  }

  defp tool_call_resp(id, name, args_json) do
    {:ok,
     %{
       "choices" => [
         %{
           "message" => %{
             "role" => "assistant",
             "content" => nil,
             "tool_calls" => [
               %{"id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => args_json}}
             ]
           },
           "finish_reason" => "tool_calls"
         }
       ],
       "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
     }}
  end

  defp text_resp(text) do
    {:ok,
     %{
       "choices" => [
         %{"message" => %{"role" => "assistant", "content" => text}, "finish_reason" => "stop"}
       ],
       "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
     }}
  end

  defp scripted(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn request ->
      fun = Agent.get_and_update(agent, fn [r | rest] -> {r, rest} end)
      if is_function(fun), do: fun.(request), else: fun
    end
  end

  defp open!(chat_fun, extra \\ []) do
    {:ok, conn} = Local.open([spec: @spec_map, chat_fun: chat_fun] ++ extra, self())
    conn
  end

  # ── (a) duplicate-call dedup ──────────────────────────────────────────────────

  test "a repeated {name, input} call is self-answered, not re-surfaced" do
    test = self()

    third = fn request ->
      send(test, {:third_request, request})
      text_resp("done")
    end

    conn =
      open!(
        scripted([
          tool_call_resp("c1", "lookup", ~s({"q":1})),
          tool_call_resp("c2", "lookup", ~s({"q":1})),
          third
        ])
      )

    # Turn 1: fresh call surfaces normally.
    {:ok, ev1, conn} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))
    assert %TurnResult{terminal: :requires_action, custom_tool_uses: [%ToolUse{id: "c1"}]} =
             Local.normalize(ev1)

    # Resume with the result; the model repeats the SAME {name, input} (new id).
    uses = [%ToolUse{id: "c1", name: "lookup", input: %{"q" => 1}}]
    results = [%ToolResult{tool_use_id: "c1", text: "answer", is_error: false}]
    {:ok, ev2, conn} = Local.poll_turn(conn, Local.resume_input(uses, results))

    # The duplicate is NOT surfaced: requires_action with zero tool uses
    # (Session resumes empty; the provider already self-answered in history).
    tr2 = Local.normalize(ev2)
    assert %TurnResult{terminal: :requires_action, custom_tool_uses: []} = tr2
    assert Enum.any?(ev2, &(&1["type"] == "local.duplicate_tool_call"))

    # Empty resume → the model is called with the duplicate self-answer in history.
    {:ok, ev3, _conn} = Local.poll_turn(conn, Local.resume_input([], []))
    assert %TurnResult{terminal: :end_turn, text: "done"} = Local.normalize(ev3)

    assert_received {:third_request, %{messages: messages}}
    dup_msg = messages |> Enum.filter(&(&1["role"] == "tool")) |> List.last()
    decoded = Jason.decode!(dup_msg["content"])
    assert decoded["duplicate"] == true
    assert decoded["message"] == Directives.duplicate_tool()
  end

  # ── (b) consecutive-error correctives ────────────────────────────────────────

  test "two consecutive errors from the same tool inject the corrective directive" do
    test = self()

    third = fn request ->
      send(test, {:third_request, request})
      text_resp("gave up")
    end

    conn =
      open!(
        scripted([
          tool_call_resp("c1", "lookup", ~s({"q":1})),
          tool_call_resp("c2", "lookup", ~s({"q":2})),
          third
        ])
      )

    {:ok, _, conn} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))

    err = fn id -> [%ToolResult{tool_use_id: id, text: "bad input", is_error: true}] end
    use_ = fn id, q -> [%ToolUse{id: id, name: "lookup", input: %{"q" => q}}] end

    # First error: no directive yet.
    {:ok, _, conn} = Local.poll_turn(conn, Local.resume_input(use_.("c1", 1), err.("c1")))

    # Second consecutive error: corrective injected before the next model call.
    {:ok, ev, _conn} = Local.poll_turn(conn, Local.resume_input(use_.("c2", 2), err.("c2")))
    assert Enum.any?(ev, &(&1["type"] == "local.directive" and &1["role"] == "corrective"))

    assert_received {:third_request, %{messages: messages}}
    corrective = Directives.corrective("lookup", "bad input")
    assert Enum.any?(messages, &(&1["role"] == "user" and &1["content"] == corrective))
  end

  test "a success resets the tool's consecutive-error count" do
    conn =
      open!(
        scripted([
          tool_call_resp("c1", "lookup", ~s({"q":1})),
          tool_call_resp("c2", "lookup", ~s({"q":2})),
          tool_call_resp("c3", "lookup", ~s({"q":3})),
          fn _ -> text_resp("done") end
        ])
      )

    {:ok, _, conn} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))

    r = fn id, err? -> [%ToolResult{tool_use_id: id, text: "t", is_error: err?}] end
    u = fn id, q -> [%ToolUse{id: id, name: "lookup", input: %{"q" => q}}] end

    {:ok, _, conn} = Local.poll_turn(conn, Local.resume_input(u.("c1", 1), r.("c1", true)))
    {:ok, _, conn} = Local.poll_turn(conn, Local.resume_input(u.("c2", 2), r.("c2", false)))
    {:ok, ev, _} = Local.poll_turn(conn, Local.resume_input(u.("c3", 3), r.("c3", true)))

    # error → success → error is NOT two consecutive: no corrective.
    refute Enum.any?(ev, &(&1["type"] == "local.directive"))
  end

  # ── (c) final-turn directive ──────────────────────────────────────────────────

  test "the last allowed poll injects the final-turn directive" do
    test = self()

    second = fn request ->
      send(test, {:final_request, request})
      text_resp("final answer")
    end

    conn =
      open!(scripted([tool_call_resp("c1", "lookup", "{}"), second]), max_turns: 2)

    {:ok, ev1, conn} = Local.poll_turn(conn, Local.kickoff_input(prompt: "go"))
    refute Enum.any?(ev1, &(&1["type"] == "local.directive"))

    uses = [%ToolUse{id: "c1", name: "lookup", input: %{}}]
    results = [%ToolResult{tool_use_id: "c1", text: "x", is_error: false}]
    {:ok, ev2, _} = Local.poll_turn(conn, Local.resume_input(uses, results))

    assert Enum.any?(ev2, &(&1["type"] == "local.directive" and &1["role"] == "final_turn"))

    assert_received {:final_request, %{messages: messages}}
    directive = Directives.final_turn("submit")
    assert Enum.any?(messages, &(&1["role"] == "user" and &1["content"] == directive))
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/req_managed_agents/providers/local_guards_test.exs`
Expected: FAIL — duplicates are re-surfaced, no directives injected.

- [ ] **Step 3: Implement the guards in `Providers.Local`**

All changes inside `lib/req_managed_agents/providers/local.ex`:

**(a)** Extend `accept_response/3` (Task 3) to partition duplicates — replace its first clause body with:

```elixir
  defp accept_response(conn, injected_events, %{
         "choices" => [%{"message" => message, "finish_reason" => finish_reason} | _]
       } = response) do
    conn = %{conn | history: conn.history ++ [message]}
    {conn, dup_events, message} = dedup_tool_calls(conn, message)

    event = %{
      "type" => "local.model_response",
      "message" => message,
      "finish_reason" => finish_reason,
      "usage" => response["usage"]
    }

    {:ok, injected_events ++ dup_events ++ [event], conn}
  end
```

And add the dedup helpers:

```elixir
  # Duplicate-call dedup (relocated from biai Core.Runner.Dispatch): a repeated
  # {name, decoded-input} call is never surfaced — the provider self-answers it in
  # history with the duplicate directive, and the surviving message carries only the
  # fresh calls. If ALL calls were duplicates the turn normalizes to :requires_action
  # with zero tool uses; the Session's empty resume drives the next model call.
  defp dedup_tool_calls(conn, %{"tool_calls" => [_ | _] = calls} = message) do
    {dups, fresh} = Enum.split_with(calls, &MapSet.member?(conn.seen, call_key(&1)))
    seen = MapSet.union(conn.seen, MapSet.new(fresh, &call_key/1))

    dup_messages =
      Enum.map(dups, fn %{"id" => id} ->
        %{
          "role" => "tool",
          "tool_call_id" => id,
          "content" =>
            Jason.encode!(%{"duplicate" => true, "message" => Directives.duplicate_tool()})
        }
      end)

    dup_events =
      Enum.map(dups, fn %{"id" => id, "function" => f} ->
        %{
          "type" => "local.duplicate_tool_call",
          "id" => id,
          "name" => f["name"],
          "input" => decode_args(f["arguments"])
        }
      end)

    message = %{message | "tool_calls" => fresh}
    conn = %{conn | seen: seen, history: conn.history ++ dup_messages}
    {conn, dup_events, message}
  end

  defp dedup_tool_calls(conn, message), do: {conn, [], message}

  defp call_key(%{"function" => %{"name" => name, "arguments" => args}}),
    do: {name, decode_args(args)}
```

Note: because `dedup_tool_calls/2` strips duplicates from the `local.model_response` message, `normalize/1` needs one adjustment — a `tool_calls: []` list on the message must still normalize to `:requires_action` when the turn had duplicates (the Session must resume so the provider can continue). Handle it via the message the event carries: in `normalize/1`, compute

```elixir
        had_dups? = Enum.any?(events, &(&1["type"] == "local.duplicate_tool_call"))
        tool_calls = message["tool_calls"] || []

        %TurnResult{
          terminal: terminal(fr, tool_calls, had_dups?),
          ...
```

and change `terminal/2` to `terminal/3`:

```elixir
  @doc false
  def terminal(_fr, [_ | _], _dups), do: :requires_action
  def terminal(_fr, [], true), do: :requires_action
  def terminal("stop", _, _), do: :end_turn
  def terminal("tool_calls", _, _), do: :requires_action
  def terminal(_other, _, _), do: :terminated
```

(Update the Task 3 `terminal/1`-style tests if the arity assertion breaks — the public surface is `normalize/1`; `terminal/3` stays `@doc false`.)

**(b)** Consecutive-error correctives + **(c)** final-turn directive — extend `apply_input/2`:

```elixir
  defp apply_input(conn, {:messages, messages}) do
    inject_final_turn(%{conn | history: conn.history ++ messages}, [])
  end

  defp apply_input(conn, {:resume, tool_uses, results}) do
    results_by_id = Map.new(results, &{&1.tool_use_id, &1})

    tool_messages =
      Enum.map(tool_uses, fn use ->
        result = Map.fetch!(results_by_id, use.id)
        %{"role" => "tool", "tool_call_id" => use.id, "content" => result_content(result)}
      end)

    conn = %{conn | history: conn.history ++ tool_messages}
    {conn, corrective_events} = apply_correctives(conn, tool_uses, results_by_id)
    inject_final_turn(conn, corrective_events)
  end

  # (b) consecutive-error correctives (relocated from biai Core.Runner): a tool that
  # errors on two consecutive dispatches gets a corrective user directive. Two passes:
  # fold the counts, then collect directives for the tools past the threshold.
  defp apply_correctives(conn, tool_uses, results_by_id) do
    error_counts =
      Enum.reduce(tool_uses, conn.error_counts, &count_error(&1, results_by_id, &2))

    correctives =
      for use <- tool_uses,
          %{is_error: true, text: err} <- [results_by_id[use.id]],
          error_counts[use.name] >= 2,
          do: Directives.corrective(use.name, err)

    conn = %{conn | error_counts: error_counts, history: conn.history ++ user_messages(correctives)}
    {conn, Enum.map(correctives, &directive_event("corrective", &1))}
  end

  defp count_error(use, results_by_id, counts) do
    case results_by_id[use.id] do
      %{is_error: true} -> Map.update(counts, use.name, 1, &(&1 + 1))
      _success -> Map.put(counts, use.name, 0)
    end
  end

  # (c) final-turn directive: the poll about to hit max_turns tells the model to finish.
  defp inject_final_turn(%{polls: polls, max_turns: max} = conn, events)
       when polls + 1 >= max do
    text = Directives.final_turn(conn.terminal_tool)

    {%{conn | history: conn.history ++ user_messages([text])},
     events ++ [directive_event("final_turn", text)]}
  end

  defp inject_final_turn(conn, events), do: {conn, events}

  defp user_messages(texts), do: Enum.map(texts, &%{"role" => "user", "content" => &1})

  defp directive_event(role, text),
    do: %{"type" => "local.directive", "role" => role, "text" => text}
```

Note: dedup self-answers (`"duplicate" => true`) are results of *skipped* dispatches — they never reach `apply_correctives` (the Session never saw those uses), so they cannot count as errors. This matches biai (`error_text/1` filters the duplicate marker as non-error).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/req_managed_agents/providers/local_guards_test.exs test/req_managed_agents/providers/local_test.exs`
Expected: all PASS.

- [ ] **Step 5: Session-level integration test**

Add to `test/req_managed_agents/providers/local_guards_test.exs`:

```elixir
  test "full Session.run: kickoff → tool → resume → end_turn through Local" do
    test = self()

    chat_fun =
      scripted([
        tool_call_resp("c1", "lookup", ~s({"q":"x"})),
        fn _ -> text_resp("the answer") end
      ])

    handler = fn name, input, _ctx ->
      send(test, {:tool_ran, name, input})
      {:ok, "found"}
    end

    assert {:ok, result} =
             ReqManagedAgents.Session.run(ReqManagedAgents.Providers.Local,
               handler: handler,
               spec: @spec_map,
               chat_fun: chat_fun,
               prompt: "question?"
             )

    assert result.terminal == :end_turn
    assert result.text == "the answer"
    assert result.turns == 2
    assert [%ToolUse{name: "lookup"}] = result.custom_tool_uses
    assert result.session_id =~ "local_"
    assert_received {:tool_ran, "lookup", %{"q" => "x"}}
    assert Enum.count(result.events, &(&1["type"] == "local.model_response")) == 2
  end
```

Run: `mix test test/req_managed_agents/providers/local_guards_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(local): loop guards relocated from biai Core.Runner

Duplicate-call dedup (self-answered in history, never re-surfaced; all-dup
turns resume empty), consecutive-error correctives (>=2 per tool), final-turn
directive (names the spec's terminal_tool). Directive wording verbatim from
biai for eval-gate continuity. New events: local.duplicate_tool_call,
local.directive." && jj new
```

---

### Task 5: `ReqLLMChat` — the default chat_fun (neutral wire ↔ ReqLLM)

**Files:**
- Create: `lib/req_managed_agents/local/req_llm_chat.ex`
- Test: `test/req_managed_agents/local/req_llm_chat_test.exs`

**Interfaces:**
- Consumes: `Local.Deps.ensure!/0`; ReqLLM 1.10+ API — `ReqLLM.generate_text(model_spec, %ReqLLM.Context{}, opts)`, `ReqLLM.Context.new/system/user/assistant(content, tool_calls:)/tool_result(id, name, content)`, `ReqLLM.ToolCall.new(id, name, arguments_json)`, `ReqLLM.Tool.new!(name:, description:, parameter_schema:, callback:)`, `ReqLLM.Response.text/1`, `ReqLLM.Response.tool_calls/1`, `ReqLLM.Response.usage/1`, per-request `:api_key` option.
- Produces: `ReqManagedAgents.Local.ReqLLMChat.chat_fun(model_config :: map()) :: (map() -> {:ok, map()} | {:error, term()})` — converts the neutral request to a ReqLLM call and the `%ReqLLM.Response{}` back to the neutral response shape. `model_config[:api_key]` → the `:api_key` generate option (the api_key carry-in for Local); `model_config[:base_url]` → the model-map `base_url` (the biai `resolve_alias` pattern).

- [ ] **Step 1: Write the tests (conversion units — no network)**

The conversion helpers are pure; test them directly and keep the network-touching `generate_text` call isolated in one thin function. Create `test/req_managed_agents/local/req_llm_chat_test.exs`:

```elixir
defmodule ReqManagedAgents.Local.ReqLLMChatTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Local.ReqLLMChat

  @request %{
    model: "openai:gpt-test",
    messages: [
      %{"role" => "system", "content" => "sys"},
      %{"role" => "user", "content" => "hi"},
      %{
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          %{"id" => "c1", "type" => "function", "function" => %{"name" => "lookup", "arguments" => ~s({"q":1})}}
        ]
      },
      %{"role" => "tool", "tool_call_id" => "c1", "content" => "found"}
    ],
    tools: [
      %{"type" => "function", "function" => %{"name" => "lookup", "description" => "d", "parameters" => %{"type" => "object"}}}
    ]
  }

  test "to_context/1 converts every neutral role" do
    ctx = ReqLLMChat.to_context(@request.messages)
    assert %ReqLLM.Context{messages: [sys, user, assistant, tool]} = ctx
    assert sys.role == :system
    assert user.role == :user
    assert assistant.role == :assistant
    assert [%ReqLLM.ToolCall{id: "c1", function: %{name: "lookup"}}] = assistant.tool_calls
    assert tool.role == :tool
  end

  test "to_tools/1 converts function declarations" do
    assert [%ReqLLM.Tool{name: "lookup", description: "d"}] = ReqLLMChat.to_tools(@request.tools)
  end

  test "model_term/2 threads base_url through the model map" do
    assert "openai:gpt-test" = ReqLLMChat.model_term("openai:gpt-test", %{})

    assert %{provider: :openai, id: "m", base_url: "http://lane/v1"} =
             ReqLLMChat.model_term("openai:m", %{base_url: "http://lane/v1"})
  end

  test "generate_opts/2 threads api_key and tools" do
    opts = ReqLLMChat.generate_opts([ReqLLM.Tool.new!(name: "t", description: "", parameter_schema: %{}, callback: fn _ -> {:error, :unused} end)], %{api_key: "vk-child"})
    assert Keyword.get(opts, :api_key) == "vk-child"
    assert [%ReqLLM.Tool{}] = Keyword.get(opts, :tools)
  end
end
```

Note for the implementer: `%ReqLLM.ToolCall{}`/`%ReqLLM.Tool{}`/message struct field names must be checked against the resolved req_llm version (`deps/req_llm/lib/req_llm/{tool_call,tool,message}.ex`) — adjust the assertions' field access (e.g. `function: %{name:}` vs flattened `name:`) to the actual structs before finalizing. The shapes above match req_llm 1.16.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/req_managed_agents/local/req_llm_chat_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement**

Create `lib/req_managed_agents/local/req_llm_chat.ex`:

```elixir
defmodule ReqManagedAgents.Local.ReqLLMChat do
  @moduledoc false
  # The DEFAULT chat_fun for Providers.Local: adapts the neutral OpenAI-shaped wire
  # contract to ReqLLM.generate_text/3. Only this module touches ReqLLM — injected
  # chat_funs never need req_llm present (Local.Deps gates construction).

  @spec chat_fun(map()) :: (map() -> {:ok, map()} | {:error, term()})
  def chat_fun(model_config) do
    ReqManagedAgents.Local.Deps.ensure!()

    fn %{model: model, messages: messages, tools: tools} ->
      result =
        ReqLLM.generate_text(
          model_term(model, model_config),
          to_context(messages),
          generate_opts(to_tools(tools), model_config)
        )

      case result do
        {:ok, response} -> {:ok, to_neutral_response(response)}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc false
  def model_term(model, %{base_url: base_url}) when is_binary(base_url) do
    case String.split(to_string(model), ":", parts: 2) do
      [provider, id] -> %{provider: String.to_atom(provider), id: id, base_url: base_url}
      [id] -> %{provider: :openai, id: id, base_url: base_url}
    end
  end

  def model_term(model, _model_config), do: model

  @doc false
  def generate_opts(tools, %{api_key: key}) when is_binary(key), do: [tools: tools, api_key: key]
  def generate_opts(tools, _model_config), do: [tools: tools]

  @doc false
  def to_context(messages) do
    messages
    |> Enum.map(&to_req_llm_message/1)
    |> ReqLLM.Context.new()
  end

  defp to_req_llm_message(%{"role" => "system", "content" => c}), do: ReqLLM.Context.system(c)
  defp to_req_llm_message(%{"role" => "user", "content" => c}), do: ReqLLM.Context.user(c)

  defp to_req_llm_message(%{"role" => "assistant", "tool_calls" => [_ | _] = calls} = m) do
    ReqLLM.Context.assistant(m["content"] || "",
      tool_calls:
        Enum.map(calls, fn %{"id" => id, "function" => %{"name" => n, "arguments" => a}} ->
          ReqLLM.ToolCall.new(id, n, a)
        end)
    )
  end

  defp to_req_llm_message(%{"role" => "assistant", "content" => c}),
    do: ReqLLM.Context.assistant(c || "")

  defp to_req_llm_message(%{"role" => "tool", "tool_call_id" => id, "content" => c}),
    do: ReqLLM.Context.tool_result(id, nil, c)

  @doc false
  def to_tools(tools) do
    Enum.map(tools, fn %{"function" => f} ->
      ReqLLM.Tool.new!(
        name: f["name"],
        description: f["description"] || "",
        parameter_schema: f["parameters"] || %{},
        callback: fn _ -> {:error, :unused} end
      )
    end)
  end

  defp to_neutral_response(response) do
    tool_calls = Enum.map(ReqLLM.Response.tool_calls(response), &to_neutral_tool_call/1)

    %{
      "choices" => [
        %{
          "message" => assistant_message(ReqLLM.Response.text(response), tool_calls),
          "finish_reason" => finish_reason(tool_calls)
        }
      ],
      "usage" => to_neutral_usage(ReqLLM.Response.usage(response))
    }
  end

  defp to_neutral_tool_call(call) do
    %{
      "id" => call.id,
      "type" => "function",
      "function" => %{"name" => call.function.name, "arguments" => call.function.arguments}
    }
  end

  defp assistant_message(text, []), do: %{"role" => "assistant", "content" => text}

  defp assistant_message(text, tool_calls),
    do: %{"role" => "assistant", "content" => text, "tool_calls" => tool_calls}

  defp finish_reason([]), do: "stop"
  defp finish_reason(_tool_calls), do: "tool_calls"

  # One shape, matched once — check the resolved req_llm's usage struct field names
  # and adjust THIS clause if they differ; do not add fallback key-chains.
  defp to_neutral_usage(%{input_tokens: input, output_tokens: output}),
    do: %{"prompt_tokens" => input, "completion_tokens" => output}

  defp to_neutral_usage(_), do: nil
end
```

Implementer notes (verify against the resolved req_llm, adjust in place):
- `ReqLLM.Context.tool_result/3` arg order is `(id, name, content)` in biai's usage; if the resolved version wants a name, pass the tool name through the neutral map (extend the `"role" => "tool"` message with `"name"` at the `Local.result_content` call site) rather than `nil`.
- `ReqLLM.Response.finish_reason` may be exposed on the response struct — if so, prefer it over inferring from tool_calls.
- `%ReqLLM.ToolCall{}` field layout (`function: %{name:, arguments:}` vs flat) — align `to_neutral_response/1` with the actual struct.

- [ ] **Step 4: Run tests to verify they pass, then wire as Local's default**

Run: `mix test test/req_managed_agents/local/req_llm_chat_test.exs test/req_managed_agents/providers/`
Expected: PASS (Task 3 already routes `default_chat_fun/1` here).

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(local): ReqLLMChat default chat_fun — neutral wire ↔ ReqLLM

model_config carries the canonical :model/:api_key/:base_url; api_key threads
into the per-request ReqLLM :api_key option, base_url through the model map
(the biai resolve_alias pattern). Injected chat_funs bypass this module
entirely." && jj new
```

---

### Task 6: api_key threading — Claude Managed Agents client construction

**Files:**
- Modify: `lib/req_managed_agents/providers/claude_managed_agents.ex` (`open/2`, `provision/2`, `teardown/2` — the `Client.new()` call sites)
- Test: `test/req_managed_agents/providers/claude_managed_agents_test.exs` (add)

**Interfaces:**
- Consumes: `Client.new/1` already resolves `:api_key` and `:base_url` from opts (`lib/req_managed_agents/client.ex:35-42`).
- Produces: the canonical `model_config` map (`:api_key`, `:base_url`) is honored when the CMA provider builds its own client — `Session.run(ClaudeManagedAgents, model_config: %{api_key: granted, base_url: routed}, ...)` needs no pre-built `:client`. An explicit `:client` opt still wins. (AgentCore signs with SigV4 — api_key does not apply; no change there.)

- [ ] **Step 1: Write the failing test**

Add to `test/req_managed_agents/providers/claude_managed_agents_test.exs`:

```elixir
  describe "model_config client threading" do
    test "open/2 builds its client from model_config api_key/base_url" do
      bypass = Bypass.open()
      test = self()

      Bypass.expect_once(bypass, "POST", "/v1/sessions", fn conn ->
        send(test, {:api_key_header, Plug.Conn.get_req_header(conn, "x-api-key")})
        Req.Test.json(conn, %{"id" => "s1"})
      end)

      Bypass.stub(bypass, "GET", "/v1/sessions/s1/events/stream", fn conn ->
        Plug.Conn.send_chunked(conn, 200)
      end)

      assert {:ok, _conn} =
               ReqManagedAgents.Providers.ClaudeManagedAgents.open(
                 [
                   agent_id: "ag",
                   environment_id: "env",
                   model_config: %{
                     api_key: "vk-granted",
                     base_url: "http://localhost:#{bypass.port}"
                   }
                 ],
                 self()
               )

      assert_received {:api_key_header, ["vk-granted"]}
    end
  end
```

(If the existing test file has no Bypass setup, follow the `run_to_completion_test.exs` idiom; the stubbed stream endpoint just needs to accept the connection.)

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/req_managed_agents/providers/claude_managed_agents_test.exs`
Expected: FAIL — `Client.new()` reads `ANTHROPIC_API_KEY`/config, not `model_config` (raises or sends the wrong key).

- [ ] **Step 3: Implement**

In `lib/req_managed_agents/providers/claude_managed_agents.ex`, add one helper and use it at the three `opts[:client] || Client.new()` sites (`provision/2`, `teardown/2`, `open/2`):

```elixir
  # Canonical model_config keys (:api_key, :base_url) build the client when no
  # explicit :client is injected — this is how a granted key + routed base_url
  # reach a session on this provider. Only the client-relevant keys are taken;
  # :model/:metadata stay opaque to this provider.
  defp client_from(opts) do
    case opts[:client] do
      nil ->
        config = opts[:model_config] || %{}
        Client.new(config |> Map.take([:api_key, :base_url]) |> Map.to_list())

      client ->
        client
    end
  end
```

Replace each `client = opts[:client] || Client.new()` with `client = client_from(opts)`.

- [ ] **Step 4: Run tests, update moduledoc, commit**

Run: `mix test test/req_managed_agents/providers/claude_managed_agents_test.exs`
Expected: PASS.

Add to the CMA moduledoc: `` A `model_config: %{api_key:, base_url:}` opt builds the client when no `:client` is injected — the canonical way to run a session on a granted key + routed base_url. ``

```bash
jj describe -m "feat(cma): api_key carry-in — model_config builds the client

model_config %{api_key:, base_url:} constructs the CMA client when no
explicit :client is given (granted key + routed base_url).
AgentCore is SigV4-signed — not applicable there." && jj new
```

---

### Task 7: metadata passthrough — `model_config[:metadata]` → telemetry + `SessionInfo`

**Files:**
- Modify: `lib/req_managed_agents/session.ex` (`init/1` meta merge, `build_info/2` → `build_info/3`), `lib/req_managed_agents/session_info.ex` (new field)
- Test: `test/req_managed_agents/session_metadata_test.exs` (create)

**Interfaces:**
- Consumes: `s.meta` (already merged into every `:telemetry.execute` metadata), `SessionInfo` ("grows by fields, never by arity"), `forward_raw/2` passing `info` to `handle_event/3`.
- Produces: `model_config[:metadata]` (map) merged into `s.meta` (over `:telemetry_metadata` on key conflict — the route response is the closer source), and `SessionInfo.metadata :: map()` so `handle_event/3` consumers see decision correlation (e.g. `mimir_request_id`, `decision_id`) without a telemetry handler. Uniform across providers — this is Session-level.

- [ ] **Step 1: Write the failing tests**

Create `test/req_managed_agents/session_metadata_test.exs`:

```elixir
defmodule ReqManagedAgents.SessionMetadataTest do
  use ExUnit.Case
  alias ReqManagedAgents.FakeProviders.RequestResponse
  alias ReqManagedAgents.Session

  defmodule InfoRecorder do
    @behaviour ReqManagedAgents.Handler
    @impl true
    def handle_tool_call(_n, _i, _c), do: {:ok, "ok"}
    @impl true
    def handle_event(_ev, test_pid, info), do: send(test_pid, {:info, info})
  end

  @end_turn [%{"type" => "stop", "terminal" => :end_turn}]

  test "model_config metadata reaches telemetry metadata" do
    handler_id = "session-metadata-telemetry-#{System.unique_integer()}"
    test = self()

    :telemetry.attach(
      handler_id,
      [:req_managed_agents, :session, :terminal],
      fn _event, _meas, meta, _cfg -> send(test, {:telemetry_meta, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _} =
      Session.run(RequestResponse,
        handler: fn _, _, _ -> {:ok, ""} end,
        turns: [@end_turn],
        telemetry_metadata: %{step_id: "step_1"},
        model_config: %{metadata: %{mimir_request_id: "req_9", decision_id: "rd_1"}}
      )

    assert_receive {:telemetry_meta, meta}
    assert meta.mimir_request_id == "req_9"
    assert meta.decision_id == "rd_1"
    assert meta.step_id == "step_1"
  end

  test "model_config metadata reaches handle_event via SessionInfo" do
    {:ok, _} =
      Session.run(RequestResponse,
        handler: InfoRecorder,
        context: self(),
        turns: [@end_turn],
        model_config: %{metadata: %{mimir_request_id: "req_9"}}
      )

    assert_receive {:info, %ReqManagedAgents.SessionInfo{metadata: %{mimir_request_id: "req_9"}}}
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/req_managed_agents/session_metadata_test.exs`
Expected: FAIL — metadata absent from telemetry meta; `SessionInfo` has no `:metadata` field.

- [ ] **Step 3: Implement**

**(a)** `lib/req_managed_agents/session_info.ex`:

```elixir
  @derive Jason.Encoder
  defstruct session_id: nil, provider: nil, metadata: %{}

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          provider: module() | nil,
          metadata: map()
        }
```

**(b)** `lib/req_managed_agents/session.ex` — in `init/1`, compute the merged meta before building state, and thread it into `build_info`:

```elixir
        meta =
          Map.merge(
            opts[:telemetry_metadata] || %{},
            model_config_metadata(opts)
          )

        state = %{
          ...
          info: build_info(provider, conn, meta),
          ...
          meta: meta,
          ...
        }
```

with:

```elixir
  # Metadata passthrough: correlation ids minted by a routing layer (request ids,
  # decision ids, …) ride model_config into telemetry AND handle_event's
  # SessionInfo, uniformly across providers. model_config wins on key conflict —
  # the route response is the closer source.
  defp model_config_metadata(opts) do
    case opts[:model_config] do
      %{metadata: %{} = m} -> m
      _ -> %{}
    end
  end
```

And `build_info/2` → `build_info/3` (update the `:reconnect` call site too):

```elixir
  defp build_info(provider, conn, meta),
    do: %SessionInfo{session_id: Map.get(conn, :session_id), provider: provider, metadata: meta}
```

In `handle_info(:reconnect, s)`: `info: build_info(s.provider, conn, s.meta),`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/req_managed_agents/session_metadata_test.exs test/req_managed_agents/telemetry_test.exs test/req_managed_agents/session_info_test.exs`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(session): metadata carry-in — model_config[:metadata] into telemetry + SessionInfo

Correlation ids ride model_config into every telemetry event's metadata and
handle_event's SessionInfo.metadata, uniformly across providers." && jj new
```

---

### Task 8: README + package repositioning — "one Session loop, any loop host"

**Files:**
- Modify: `README.md` (title/premise section + provider list), `mix.exs` (`description`), `lib/req_managed_agents/session.ex` + `lib/req_managed_agents.ex` (moduledoc premise sentence where it says the provider runs the loop server-side)

**Interfaces:**
- Consumes: Tasks 3–5 (Local must exist before the README claims it).
- Produces: the positioning change from the position doc §3 — vocabulary (`custom_tool_use`/`custom_tool_result`, three-atom terminal, `%SessionResult{}`) unchanged.

- [ ] **Step 1: Update `mix.exs` description**

```elixir
      description:
        "Provider-agnostic Elixir client for agent runtimes — one Session loop, any " <>
          "loop host: server-side (Anthropic Claude Managed Agents, AWS Bedrock " <>
          "AgentCore) or in-process (Local, over any OpenAI-compatible chat endpoint). " <>
          "Your tools run locally.",
```

- [ ] **Step 2: Update `README.md`**

Read the current README premise section first. Apply:
- The one-line pitch becomes: **"One Session loop, any loop host — server-side (Claude Managed Agents, AgentCore) or in-process (Local)."**
- The provider table/list gains a third row: `ReqManagedAgents.Providers.Local` — `:request_response`, in-process loop over a pluggable `chat_fun` (default: ReqLLM via the optional `req_llm` dep); one model call per turn; loop guards for weak-instruction-following local models.
- Add a short "Local + routing" paragraph (position doc's routing note): pointing Local's `chat_fun` at an OpenAI-compatible gateway lane (base_url + per-run api_key via `model_config`) gives hard data-plane budget enforcement without any coupling; direct-to-provider chat_funs remain for dev/tests. Include the minimal example:

```elixir
{:ok, result} =
  ReqManagedAgents.Session.run(ReqManagedAgents.Providers.Local,
    handler: MyTools,
    spec: %{system_prompt: "...", tools: tools, terminal_tool: "submit", model_config: nil},
    model_config: %{model: "openai:gpt-oss", base_url: lane_url, api_key: granted_key},
    prompt: "Go."
  )
```

- Statements like "the provider runs the agent loop server-side" (README + `Session`/`ReqManagedAgents` moduledocs) become "the loop host runs the agent loop — a managed provider server-side, or `Providers.Local` in-process".

- [ ] **Step 3: Verify docs build and commit**

Run: `mix docs && mix test`
Expected: clean build, suite green.

```bash
jj describe -m "docs: reposition — one Session loop, any loop host (server-side or in-process)" && jj new
```

---

### Task 9: Ollama live test (`:external`)

**Files:**
- Create: `test/live/local_ollama_test.exs`

**Interfaces:**
- Consumes: `Providers.Local` with an injected bare-Req chat_fun (also proves the mimir-lane pattern needs no adapter; runs with req_llm absent).
- Produces: the one live Local test from the position doc §8. Tagged `:external` — excluded by default (confirm the exclusion in `test/test_helper.exs`; the live smoke tests there are the pattern).

- [ ] **Step 1: Write the test**

Create `test/live/local_ollama_test.exs`:

```elixir
defmodule ReqManagedAgents.Live.LocalOllamaTest do
  # Live test against a local Ollama (`ollama serve`, model pulled, e.g.
  # `ollama pull qwen3:4b`). Run explicitly:
  #   OLLAMA_MODEL=qwen3:4b mix test test/live/local_ollama_test.exs --include external
  use ExUnit.Case
  @moduletag :external

  alias ReqManagedAgents.{Providers.Local, Session}

  @base_url "http://localhost:11434/v1"

  defp ollama_chat_fun do
    # The mimir-lane shape: a bare POST to an OpenAI-compatible /chat/completions.
    fn %{model: model, messages: messages, tools: tools} ->
      body = %{model: model, messages: messages, tools: tools}

      case Req.post("#{@base_url}/chat/completions", json: body, receive_timeout: 120_000) do
        {:ok, %{status: 200, body: resp}} -> {:ok, resp}
        {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
        {:error, reason} -> {:error, %{reason: reason}}
      end
    end
  end

  test "Local drives a real tool round-trip against Ollama" do
    model = System.get_env("OLLAMA_MODEL") || "qwen3:4b"
    test = self()

    spec = %{
      system_prompt:
        "You have a get_secret tool. Call it, then answer with ONLY the secret word.",
      tools: [
        %{
          "name" => "get_secret",
          "description" => "Returns the secret word.",
          "input_schema" => %{"type" => "object", "properties" => %{}}
        }
      ],
      terminal_tool: nil,
      model_config: nil
    }

    handler = fn "get_secret", _input, _ctx ->
      send(test, :tool_called)
      {:ok, "zanzibar"}
    end

    assert {:ok, result} =
             Session.run(Local,
               handler: handler,
               spec: spec,
               model_config: %{model: model},
               chat_fun: ollama_chat_fun(),
               prompt: "What is the secret word?",
               max_turns: 6,
               timeout: 300_000
             )

    assert result.terminal == :end_turn
    assert_received :tool_called
    assert result.text |> String.downcase() =~ "zanzibar"
    assert result.usage.input_tokens > 0
  end
end
```

- [ ] **Step 2: Run it against a live Ollama (when available)**

Run: `mix test test/live/local_ollama_test.exs --include external`
Expected: PASS with Ollama running; the whole file is skipped in a normal `mix test`. If no Ollama is available in the execution environment, verify the skip (`mix test` shows it excluded) and note BLOCKED-partial in the task report rather than faking a pass.

- [ ] **Step 3: Commit**

```bash
jj describe -m "test(local): :external Ollama live round-trip (bare-Req chat_fun, mimir-lane shape)" && jj new
```

---

### Task 10: QA-CHECKPOINT — Local-provider release gate

**Files:**
- Create: `docs/qa/<run-date>-local-provider-manual-test.md` (house header: Date / Tester / Commits under test / Worktree / Scope — no tracker ids)
- Scratch (author, run, then DELETE before committing): `test/qa_local_provider_scratch.exs`

**Interfaces:**
- Consumes: Tasks 1–9.
- Produces: a PASS verdict in the runbook. **Task 11 (release) does not start until PASS.** Failures become fix tasks, then re-run.

- [ ] **Step 1: Baseline**

`mix test 2>&1 | grep -E "^(Finished|Result)"` — record counts; the final step must reproduce them.

- [ ] **Step 2: Author and run the scratch scenarios**

The unit tasks proved each Local mechanism with a scripted chat_fun in isolation. The gate proves multi-request lifecycles, interplay with the 0.5.0 governance features, and the two carry-ins end-to-end:

| # | Scenario | Method | Expected |
|---|---|---|---|
| 1 | Multi-turn live session on Local | `Session.start_link` + two `message/2` follow-ups, scripted chat_fun recording every request | History grows monotonically across requests (system + all prior turns present in request 3); `turns` resets per request; each follow-up yields its own `:managed_agents_session` notify |
| 2 | turn_guard halts a Local tool loop | Scripted chat_fun that always requests a fresh tool; guard halts at `turns >= 3` | `{:error, {:halted, _}}` + `:terminated` notify; no further chat_fun calls after the halt |
| 3 | Terminal-tool re-prompt vs final-turn directive | `max_turns: 3`, `require_terminal_tool` + `terminal_tool: "submit"`, model never calls it | Both mechanisms fire without conflict: Session re-prompts via `user_input`, Local injects the final-turn directive on the poll hitting `max_turns`; record the exact message sequence the chat_fun saw as documentation of the combined behavior |
| 4 | Mixed dedup batch | Turn N requests `[duplicate, fresh]` in ONE response | Only the fresh call surfaces (handler runs once); duplicate self-answered in history; next request carries tool results for BOTH ids (valid OpenAI pairing); `local.duplicate_tool_call` event present |
| 5 | Retry inside a full run | chat_fun: 503, 503, then tool_call, then stop; `sleep_fun` records delays | Run succeeds end-to-end; recorded delays `[1000, 2000]`-shaped per config; usage accumulated only for successful calls |
| 6 | api_key end-to-end through the DEFAULT chat_fun | Bypass as OpenAI-compatible `/chat/completions`; `model_config: %{model: "openai:qa-model", base_url: <bypass>, api_key: "qa-key-1"}`; NO injected chat_fun | Bypass receives the request with the key in the auth header (record the exact header ReqLLM uses); request body carries messages + tools in wire shape |
| 7 | Metadata passthrough on Local | `model_config: %{metadata: %{request_id: "r1"}}` + telemetry handler + module handler | Telemetry terminal event meta and `SessionInfo.metadata` both carry `request_id: "r1"` |
| 8 | LIVE Ollama round-trip (optional leg) | Probe first: `curl -s --max-time 2 localhost:11434/api/tags`. If up: `mix test test/live/local_ollama_test.exs --include external` | Task 9's test passes against the live model; paste the result line. If Ollama absent: mark the leg **SKIPPED** — never report a skip as a pass |
| 9 | Package sanity | `mix hex.build && mix docs` | Package builds; file list contains `lib/req_managed_agents` only (no test/qa scratch); docs clean |

- [ ] **Step 3: Clean up and confirm the baseline**

Delete the scratch file; `mix test` reproduces Step 1's counts exactly. Record.

- [ ] **Step 4: Verdict + commit**

Runbook ends with `RESULT: PASS — N/N scenarios (M skipped-live)`. Commit:

```bash
jj describe -m "qa: Local-provider release-gate checkpoint (PASS)" && jj new
```

---

### Task 11: Release 0.6.0 — version bump + CHANGELOG

**Files:**
- Modify: `mix.exs:4` (`@version "0.5.0"` → `@version "0.6.0"`)
- Modify: `CHANGELOG.md` (new entry above `## v0.5.0`)

**Interfaces:**
- Consumes: Tasks 1–9; Task 10's PASS verdict.
- Produces: version `0.6.0` — the release RMA 0.7.0 (agent management) and the biai SP7 flip build on.

- [ ] **Step 1: Bump the version**

In `mix.exs`: `@version "0.6.0"`.

- [ ] **Step 2: Add the CHANGELOG entry**

```markdown
## v0.6.0 (2026-07-04)

### Added
- **`ReqManagedAgents.Providers.Local`** — the third provider: the agent loop runs
  in-process (`:request_response`, one model call per turn) over a pluggable
  `chat_fun` with a neutral OpenAI-chat-completions-shaped wire contract
  (`chat_fun.(%{model:, messages:, tools:}) :: {:ok, response} | {:error, reason}`).
  Pointing the chat_fun at any OpenAI-compatible endpoint is a bare `Req.post` —
  including a gateway lane with a granted key for hard data-plane budget
  enforcement. Events are synthesized under the `local.*` namespace
  (`local.model_response`, `local.duplicate_tool_call`, `local.directive`);
  `provision/2` is identity.
- Local loop guards (relocated from biai-managed-agents `Core.Runner`, for
  weak-instruction-following local models): duplicate-call dedup (self-answered,
  never re-surfaced), consecutive-error corrective directives (≥2 per tool),
  final-turn directive (names the spec's `terminal_tool`), and transient-error
  retry with exponential backoff around the chat call (HTTP 408/≥500 + transport
  errors; `max_chat_retries`/`retry_backoff_ms`/`sleep_fun` opts).
- Optional `req_llm` dependency (`~> 1.10`, raise-at-first-use via
  `Local.Deps`) backing the default chat_fun; `model_config[:api_key]` and
  `[:base_url]` thread into the ReqLLM call.
- api_key carry-in: the Claude Managed Agents provider builds its client from
  `model_config: %{api_key:, base_url:}` when no `:client` is injected.
  (Bedrock AgentCore signs with SigV4 — not applicable.)
- Metadata carry-in: `model_config[:metadata]` merges into every telemetry
  event's metadata and into `SessionInfo.metadata` for `handle_event/3` —
  decision correlation (`mimir_request_id`, `decision_id`) rides uniformly
  across providers.

### Changed
- Positioning: "one Session loop, any loop host — server-side (Claude Managed
  Agents, AgentCore) or in-process (Local)". README, package description, and
  moduledocs updated; vocabulary and result shapes unchanged.
```

- [ ] **Step 3: Verify the release builds clean**

Run: `mix test && mix docs && mix credo --strict`
Expected: suite green, docs clean; fix any credo findings introduced by this release before committing.

- [ ] **Step 4: Commit**

```bash
jj describe -m "release: v0.6.0 — Providers.Local, loop guards, api_key + metadata carry-ins" && jj new
```
