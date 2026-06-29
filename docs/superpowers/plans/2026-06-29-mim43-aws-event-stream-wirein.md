# MIM-43 — `aws_event_stream` Wire-In Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the internals of `ReqManagedAgents.AgentCore.EventStream.decode/1` with a delegation to the published `aws_event_stream` v0.1.0, deleting RMA's vendored `vnd.amazon.eventstream` framing codec while preserving `decode/1`'s public contract byte-for-byte.

**Architecture:** `aws_event_stream`'s `AWSEventStream.JSON.decode/1` already does framing + CRC + header parsing + `:message-type` classification + payload unwrap, returning the same chunked `{[…], remainder}` shape. `EventStream` collapses to a thin adapter that maps the lib's classified tuples (`{:event, …}` / `{:exception, …}` / `{:error, …}` / `{:malformed_*}`) into the Converse envelope (`%{event_type => payload}` / `%{"__stream_error__" => …}`) its consumers already expect. No consumer changes; no contract change.

**Tech Stack:** Elixir, `aws_event_stream` (github tag `v0.1.0`), `jason`, ExUnit.

**Working directory:** the `mim43` jj workspace at `/Users/ryanmckeeman/src/bizinsights/req_managed_agents/.claude/worktrees/mim43` (already created, based on merged main). All paths below are relative to it. This repo uses **jj**, not git — commit steps use jj.

**Reference:** spec at `docs/superpowers/specs/2026-06-29-mim43-aws-event-stream-wirein-design.md`.

---

### Task 1: Add the `aws_event_stream` dependency

**Files:**
- Modify: `mix.exs` (the `deps/0` list)

- [ ] **Step 1: Add the dependency**

In `mix.exs`, inside `defp deps do [...]`, add the `aws_event_stream` git dependency immediately after the `{:ex_aws_auth, "~> 1.4"},` line:

```elixir
      {:ex_aws_auth, "~> 1.4"},
      {:aws_event_stream, github: "cash-mckeeman/aws_event_stream", tag: "v0.1.0"},
```

- [ ] **Step 2: Fetch and compile the dependency**

Run: `mix deps.get && mix compile`
Expected: `aws_event_stream` is fetched at tag `v0.1.0` and the project compiles cleanly. The vendored `EventStream` module is still in place and unchanged, so there are no warnings or errors.

- [ ] **Step 3: Verify the lib's entrypoint is callable**

Run: `mix run -e 'IO.inspect(AWSEventStream.JSON.decode(<<>>))'`
Expected output: `{[], ""}` — confirms `AWSEventStream.JSON.decode/1` is available and returns the `{classified_list, remainder}` shape.

- [ ] **Step 4: Commit**

```bash
jj describe @ -m "build(mim43): add aws_event_stream v0.1.0 dependency

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
jj new
```

---

### Task 2: Swap `EventStream` to the thin adapter

**Files:**
- Modify: `lib/req_managed_agents/agent_core/event_stream.ex` (replace the module body)
- Modify: `test/req_managed_agents/agent_core/event_stream_test.exs` (add two tests)

This task is driven by a new test (`error`-frame surfacing) that the *old* code fails, and guarded by the 7 existing tests that must stay green to prove the swap is behavior-preserving.

- [ ] **Step 1: Add the two new classified-variant tests**

Append these two tests inside the `defmodule ReqManagedAgents.AgentCore.EventStreamTest` block in `test/req_managed_agents/agent_core/event_stream_test.exs`, just before the final `end`. They reuse the existing `frame/1`, `str_header/2`, and `frame_with_headers/2` helpers already defined in that file:

```elixir
  test ":message-type error frame surfaces as __stream_error__ with the header's error-message" do
    # An `error` frame (distinct from `exception`) carries its detail in the
    # :error-code / :error-message headers, not the body. The lib classifies it as
    # {:error, code, message}; the adapter maps that to the __stream_error__ envelope
    # so agent_core's stream_error/1 surfaces it (message is a plain string here).
    headers_bin =
      str_header(":message-type", "error") <>
        str_header(":error-code", "throttling") <>
        str_header(":error-message", "slow down")

    f = frame_with_headers(headers_bin, ~s({}))

    assert {[event], ""} = EventStream.decode(f)

    assert event == %{
             "__stream_error__" => %{"type" => "throttling", "message" => "slow down"}
           }
  end

  test "a CRC-valid event frame with a non-JSON body is dropped" do
    # No :message-type / :event-type headers → classified as an :event whose payload
    # fails to decode → {:malformed_payload, _, _} → dropped. Preserves the prior
    # 'an undecodable body is noise' posture (an exception body, by contrast, is kept).
    f = frame("this is not valid json")
    assert {[], ""} = EventStream.decode(f)
  end
```

- [ ] **Step 2: Run the test file against the current (vendored) implementation**

Run: `mix test test/req_managed_agents/agent_core/event_stream_test.exs`
Expected: **the `error` frame test FAILS**, because the vendored code derives the error message from the decoded body (`%{}`) rather than the `:error-message` header — the assertion `message => "slow down"` will mismatch with `message => %{}`. The other 8 tests (7 existing + the non-JSON-body test) pass. This RED confirms the new behavior is genuinely driven by the swap.

- [ ] **Step 3: Replace the `EventStream` module with the thin adapter**

Replace the **entire contents** of `lib/req_managed_agents/agent_core/event_stream.ex` with:

```elixir
defmodule ReqManagedAgents.AgentCore.EventStream do
  @moduledoc """
  Adapter from `aws_event_stream`'s classified frames to the Converse envelope
  `ReqManagedAgents.AgentCore.Converse.parse/1` consumes.

  Framing, CRC verification, header parsing, `:message-type` classification, and
  Bedrock payload unwrap all live in `AWSEventStream` (the published binary
  `vnd.amazon.eventstream` codec). This module owns only the AgentCore-specific
  shaping of the classified frames:

    * `{:event, type, payload}`        -> `%{type => payload}` (the Converse
      envelope), or `payload` as-is when the frame carries no `:event-type`.
    * `{:exception, type, payload}` /
      `{:error, code, message}`        -> `%{"__stream_error__" => %{"type" => …,
      "message" => …}}`, so a server-side close (e.g. a ConverseStream
      ValidationException) surfaces as a distinct error rather than a silent
      terminal (MIM-50/MIM-52). `AgentCore.agent_core`'s `stream_error/1` reads
      this shape.
    * malformed frames / payloads      -> dropped (the prior recovery posture).

  `decode/1`'s `{[map()], binary()}` contract and incremental (chunked-buffer)
  semantics are preserved exactly — `AWSEventStream.JSON.decode/1` is itself
  incremental, buffering an incomplete trailing frame as `remainder`.
  """

  @spec decode(binary()) :: {[map()], binary()}
  def decode(buffer) when is_binary(buffer) do
    {classified, remainder} = AWSEventStream.JSON.decode(buffer)
    {Enum.flat_map(classified, &to_envelope/1), remainder}
  end

  defp to_envelope({:event, nil, payload}), do: [payload]
  defp to_envelope({:event, type, payload}), do: [%{type => payload}]

  defp to_envelope({:exception, type, payload}),
    do: [%{"__stream_error__" => %{"type" => type, "message" => payload}}]

  defp to_envelope({:error, code, message}),
    do: [%{"__stream_error__" => %{"type" => code, "message" => message}}]

  defp to_envelope({:malformed_payload, _msg, _reason}), do: []
  defp to_envelope({:malformed_frame, _reason, _raw}), do: []
end
```

- [ ] **Step 4: Run the test file against the adapter**

Run: `mix test test/req_managed_agents/agent_core/event_stream_test.exs`
Expected: **all 9 tests pass** — the 7 existing (byte-level preservation), the new `error`-frame test (now green), and the non-JSON-body drop test.

- [ ] **Step 5: Run the full suite + strict compile + format**

Run: `mix format && mix compile --warnings-as-errors && mix test`
Expected: format clean; no warnings; **all tests pass**. In particular `converse_test.exs`, `agent_core_test.exs` (the MIM-52 id-keying and the `:harness_stream_error` surfacing), and `smoke_test.exs` pass without edits — the proof the swap is transparent to every consumer.

- [ ] **Step 6: Commit**

```bash
jj describe @ -m "refactor(agent_core): delegate EventStream framing to aws_event_stream

Replace the vendored vnd.amazon.eventstream codec (~110 LOC) with a thin adapter
over AWSEventStream.JSON.decode/1. decode/1's {[map()], binary()} -> Converse
envelope contract is preserved byte-for-byte (the 7 existing event_stream_test
cases pass unchanged); framing/CRC/headers/classification now live in the lib.
Adds an error-frame test (header-derived message) and a malformed-payload drop
test. No consumer changes; :harness_stream_error untouched. MIM-43.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
jj new
```

---

## Final verification

After both tasks, confirm the deletion landed and nothing regressed:

- [ ] Run `mix compile --warnings-as-errors && mix test` → all green, no warnings.
- [ ] Run `grep -nE "decode_loop|parse_headers|tag_frame|stream_error_type|crc32" lib/req_managed_agents/agent_core/event_stream.ex` → **no matches** (the vendored framing is gone; only the adapter remains).
- [ ] Run `jj log -r 'main..@-' --no-graph -T 'description.first_line() ++ "\n"'` → shows the two MIM-43 commits (dependency, refactor) on top of main.
