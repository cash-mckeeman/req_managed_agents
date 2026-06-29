# MIM-43 — `aws_event_stream` Wire-In Design

**Date:** 2026-06-29
**Status:** Draft (design approved; implementation-ready)
**Related:** MIM-43 (provider extraction endgame), MIM-50 / MIM-52 (the EventStream surfacing + Converse id-keying this preserves), `2026-06-29-provider-streaming-abstraction-design.md` (the larger abstraction this composes under), `aws_event_stream` v0.1.0 (the published lib)

## Goal

Replace the **internals** of `ReqManagedAgents.AgentCore.EventStream.decode/1` with a delegation to the published `aws_event_stream` library, deleting RMA's vendored `vnd.amazon.eventstream` framing codec (~110 LOC) while preserving `decode/1`'s public contract **byte-for-byte**.

This is the "future extraction" named in the Provider Streaming Abstraction spec (§Migration: *"a future extraction may adopt `aws_event_stream` for the binary side"*). It is the binary-transport half of provider-agnosticism — nothing more.

## Scope

**In scope:**

1. Add `aws_event_stream` v0.1.0 as a dependency.
2. Reduce `ReqManagedAgents.AgentCore.EventStream` to a thin adapter that delegates framing/CRC/header/classification to `AWSEventStream.JSON.decode/1` and shapes the result into the Converse envelope its consumers already expect.
3. Delete the vendored framing internals (`decode_loop/2`, CRC verification, `parse_headers/1`, `tag_frame/2`, `stream_error_type/1`).

**Out of scope (explicitly):**

- **The `Provider` behaviour / canonical turn vocabulary** — owned by `2026-06-29-provider-streaming-abstraction-design.md`. This spec touches only the transport codec beneath `EventStream.decode/1`.
- **Any run-outcome / stream-error contract change.** That spec deliberately keeps `:harness_stream_error` and other driver-level conditions out of the shared behaviour ("the behaviour models what the *model/turn* did, not what the *transport* did"). This spec therefore makes **no** rename and **no** change to how errors surface: `agent_core`'s `{:error, {:harness_stream_error, type, message}}` is untouched.
- **The CMA / SSE side.** `ReqManagedAgents.SSE` stays in-tree; per the abstraction spec, the SSE library already exists if ever needed.
- **`Converse.parse/1`, `agent_core`, `Client`, the smoke task.** All consume `EventStream.decode/1`'s output, whose shape is preserved, so none change.

## The seam

`aws_event_stream` is a strict superset of RMA's vendored framing. `AWSEventStream.JSON.decode/1` already does framing + CRC + header parsing + `:message-type` classification + Bedrock payload unwrap, returning the **same chunked `{[…], remainder}` shape** RMA needs:

```elixir
@type classified ::
        {:event, String.t() | nil, map()}
        | {:exception, String.t() | nil, map()}
        | {:error, String.t() | nil, String.t() | nil}
        | {:malformed_payload, Message.t(), term()}

# Frame-level decode errors (CRC/length/headers) are surfaced as a distinct
# {:malformed_frame, reason, raw} arm alongside the classified frames.
@spec decode(binary(), keyword()) ::
        {[classified() | {:malformed_frame, atom(), binary()}], binary()}
```

The only RMA-specific logic that must survive is **Converse envelope shaping** — turning those tuples into the `%{event_type => payload}` / `%{"__stream_error__" => …}` maps that `Converse.parse/1` and `agent_core`'s `stream_error/1` consume today.

## Design — the thin adapter

`ReqManagedAgents.AgentCore.EventStream` becomes:

```elixir
defmodule ReqManagedAgents.AgentCore.EventStream do
  @moduledoc """
  Adapter from `aws_event_stream`'s classified frames to the Converse envelope
  `Converse.parse/1` consumes. Framing, CRC, header parsing, message-type
  classification, and Bedrock payload unwrap all live in `AWSEventStream`; this
  module owns only the AgentCore-specific shaping:

  - `{:event, type, payload}`  → `%{type => payload}` (or `payload` as-is when the
    frame carries no `:event-type`), matching the documented Converse envelope.
  - `{:exception, type, payload}` / `{:error, code, msg}` → `%{"__stream_error__" =>
    %{"type" => …, "message" => …}}`, so a server-side close (e.g. a ConverseStream
    ValidationException) surfaces as a distinct error rather than a silent terminal
    (MIM-50/MIM-52). `agent_core`'s `stream_error/1` consumes this shape.
  - malformed frames/payloads are dropped (the prior recovery posture).
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

`decode/1` keeps its `@spec decode(binary()) :: {[map()], binary()}` and its incremental (chunked-buffer) semantics, because `AWSEventStream.JSON.decode/1` is itself incremental (buffers an incomplete trailing frame as `remainder`).

## Dependency

Add to `mix.exs` `deps/0`:

```elixir
{:aws_event_stream, github: "cash-mckeeman/aws_event_stream", tag: "v0.1.0"},
```

`aws_event_stream`'s JSON layer requires `:jason`, already an RMA dependency. No other transitive additions.

## Behavior preservation

The existing `test/req_managed_agents/agent_core/event_stream_test.exs` (7 tests) is the byte-level contract. Each was walked against `AWSEventStream.JSON.classify/1` + the adapter mapping above and passes **unchanged**:

| Existing test | Lib path → adapter | Result |
|---|---|---|
| single complete frame → payload map | `{:event, nil, payload}` → `[payload]` | ✓ |
| trailing partial bytes → remainder | `Decoder` buffers incomplete frame | ✓ |
| `:event-type` wraps payload | `{:event, "contentBlockStart", p}` → `%{"contentBlockStart" => p}` | ✓ |
| `:message-type` exception → `__stream_error__` | `{:exception, "runtimeClientError", %{"message"=>…}}` → tagged map | ✓ (exact) |
| `:event-type` contentBlockDelta | `{:event, "contentBlockDelta", p}` → wrapped | ✓ |
| no `:event-type` (legacy) → passthrough | `:message-type` nil → `{:event, nil, p}` → `[p]` | ✓ |
| corrupted message CRC → dropped, remainder `""` | Decoder **consumes** frame, emits `{:error, {:invalid_message_crc, _}}` → `{:malformed_frame, …}` → dropped | ✓ |

These 7 tests stay in place and must remain green — that is the proof the swap is transparent.

**Two tests are added** to cover classified variants the existing corpus does not exercise (both are pure-data, no network):

1. **`:message-type` `error` frame → `__stream_error__`.** A frame with `:message-type "error"`, `:error-code "throttling"`, `:error-message "slow down"` decodes to `{:error, "throttling", "slow down"}` → `%{"__stream_error__" => %{"type" => "throttling", "message" => "slow down"}}`. (`agent_core`'s `stream_error_message/1` already handles a string `message`.)
2. **Malformed payload in a CRC-valid event frame → dropped.** A well-formed frame whose body is not valid JSON classifies as `{:malformed_payload, _, _}` and is dropped (`{[], ""}`), preserving the prior "undecodable body is noise" posture.

**Downstream tests unchanged:** `converse_test.exs`, `agent_core_test.exs` (including the MIM-52 id-keying and the `:harness_stream_error` surfacing), and `smoke_test.exs` consume `decode/1`'s preserved output and must pass without edits.

### Minor, documented behavior delta

For an **exception frame whose body is not JSON**, the lib preserves the raw bytes as `%{"raw" => body}` (via `exception_payload/1`), whereas the vendored code surfaced the raw string directly as `message`. The resulting `__stream_error__.message` is therefore `%{"raw" => "…"}` instead of `"…"`. `agent_core`'s `stream_error_message/1` already falls through non-`%{"message" => binary}` shapes unchanged, so the error still surfaces; only the inspected message representation differs. No existing test exercises this path (all use JSON exception bodies), so none changes. Called out here for fidelity.

## Risk

- **Low, additive-then-subtractive.** One module's internals are replaced behind a preserved public spec; the deleted code's behavior is re-established by the lib and proven by the unchanged test corpus.
- **New dependency** (`aws_event_stream` via git tag) — intentional; this is the extraction MIM-43 exists to do.
- **Composition with the Provider abstraction:** both specs pin `EventStream.decode/1 :: {[map()], binary()}` as the stable seam, so this swap and the later `Providers.AgentCore` wrapper are orthogonal and order-independent.

## Non-goals recap

- No `Provider` behaviour, no canonical turn vocabulary — that is the abstraction spec.
- No `:harness_stream_error` rename, no run-outcome / stream-error contract change.
- No CMA / SSE changes.
- No `ant_event_stream` (there is no Anthropic binary protocol — SSE is text).
