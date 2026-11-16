# AWSEventStream

Pure-Elixir codec for the AWS `vnd.amazon.eventstream` binary protocol.

General-purpose and symmetric: encodes and decodes all header types, validates
CRC32 checksums on both the prelude and the whole message, and surfaces every
frame error explicitly instead of silently dropping bad data. The design mirrors
`aws-sdk-go-v2/aws/protocol/eventstream` and botocore — same wire format, same
header-type set, same signed big-endian numerics.

The core codec is payload-agnostic (payloads are opaque bytes). An optional JSON
convenience layer classifies frames by `:message-type` and unwraps Bedrock-style
JSON payloads.

## Installation

Add `aws_event_stream` to your `mix.exs`:

```elixir
{:aws_event_stream, "~> 0.2"}
```

The `jason` dependency is only needed if you use `AWSEventStream.JSON`. Add it
explicitly if so:

```elixir
{:aws_event_stream, "~> 0.2"},
{:jason, "~> 1.4"},
```

## Core encode / decode

```elixir
alias AWSEventStream.{Header, Message}

# Build a message with a string header and a binary payload.
msg = %Message{
  headers: [
    %Header{name: ":message-type", type: :string, value: "event"},
    %Header{name: ":event-type",   type: :string, value: "contentBlockDelta"}
  ],
  payload: ~s({"delta":{"text":"hello"}})
}

# Encode to a complete event-stream frame (returns iodata).
frame = IO.iodata_to_binary(AWSEventStream.encode(msg))

# Decode a buffer — returns {results, leftover_bytes}.
# Feed leftover bytes into the next call when streaming chunks.
{[{:ok, ^msg}], <<>>} = AWSEventStream.decode(frame)
```

`decode/1,2` is incremental: call it on each incoming chunk, prepend the
returned `rest` to the next chunk, and repeat.

```elixir
# Streaming example: simulate two chunks split across a frame boundary.
{part1, part2} = :erlang.split_binary(frame, 10)

{[], rest1}           = AWSEventStream.decode(part1)
{[{:ok, msg}], <<>>} = AWSEventStream.decode(rest1 <> part2)
```

### Error handling

Corrupt frames are returned as `{:error, {reason, raw_bytes}}` rather than
raised — your stream is never interrupted:

```elixir
{[{:error, {:invalid_message_crc, _raw}}], <<>>} = AWSEventStream.decode(corrupt_bytes)

# Pass on_error: :skip to silently drop corrupt frames.
{[], <<>>} = AWSEventStream.decode(corrupt_bytes, on_error: :skip)
```

Possible `reason` atoms: `:invalid_prelude_crc`, `:invalid_message_crc`,
`:invalid_message_length`.

## JSON layer (`AWSEventStream.JSON`)

Bedrock and other AWS streaming APIs attach a `:message-type` header
(`"event"` / `"exception"` / `"error"`) to every frame. Without explicit
classification, a consumer receiving unexpected data cannot tell whether
it got a server-side throttling exception or a normal event that happens
to contain a map with a field named `"error"`. `AWSEventStream.JSON.decode/2`
resolves this: it classifies each frame before inspecting the payload, so
the tagged tuple is always authoritative.

```elixir
alias AWSEventStream.JSON

# Decode a buffer of raw event-stream bytes.
{classified, rest} = JSON.decode(buffer)

# Each result is one of:
#   {:event,            event_type :: String.t() | nil, payload :: map()}
#   {:exception,        exception_type :: String.t() | nil, payload :: map()}
#   {:error,            error_code :: String.t() | nil, message :: String.t() | nil}
#   {:malformed_payload, %Message{}, reason}
#   {:malformed_frame,  reason :: atom(), raw_bytes :: binary()}

for result <- classified do
  case result do
    {:event, type, payload} ->
      IO.puts("event #{type}: #{inspect(payload)}")

    {:exception, type, payload} ->
      # Server signalled an exception — distinct from a normal event.
      IO.puts("exception #{type}: #{inspect(payload)}")

    {:error, code, message} ->
      # Wire-level error (e.g. InternalFailure) — also distinct from {:event, ...}.
      IO.puts("error #{code}: #{message}")

    {:malformed_payload, _msg, reason} ->
      IO.puts("payload could not be decoded: #{inspect(reason)}")

    {:malformed_frame, reason, _raw} ->
      IO.puts("corrupt frame: #{inspect(reason)}")
  end
end
```

### Disambiguating server-side early closes

AWS streaming services terminate abnormal streams with an `exception` or `error`
frame rather than just closing the connection. Without explicit `:message-type`
classification a consumer cannot distinguish:

- `{:event, "chunk", %{"text" => "..."}}` — normal streaming chunk
- `{:exception, "throttlingException", %{"message" => "Rate exceeded"}}` — server throttled
- `{:error, "InternalFailure", "boom"}` — server-side internal error

The JSON layer makes this distinction at the decode step so application code
can pattern-match cleanly instead of introspecting raw headers. A frame's
classification is fixed by its headers, so an `exception`/`error` frame is
*always* surfaced as `{:exception, …}` / `{:error, …}` — even when its body is
non-JSON or empty (a server-side close may legitimately send one). For an
exception frame whose body isn't a JSON object the raw bytes are preserved under
`"raw"`, e.g. `{:exception, "ValidationException", %{"raw" => "..."}}`. Only
normal `event` frames degrade to `{:malformed_payload, …}` on an undecodable
payload.

Bedrock payloads are automatically unwrapped: if the outer JSON is
`{"bytes": "<base64>"}`, the inner bytes are base64-decoded and the nested JSON
object is returned as the payload map.

## Frame format

All numbers are big-endian. CRCs use Erlang's `:erlang.crc32/1`.

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       total_length (u32)                       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      headers_length (u32)                      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      prelude_crc (u32)                         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         headers (variable)                     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         payload (variable)                     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       message_crc (u32)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

- `total_length` — total frame bytes including this field and `message_crc`
- `headers_length` — byte length of the headers block
- `prelude_crc` — CRC32 of the first 8 bytes (`total_length` + `headers_length`)
- `message_crc` — CRC32 of every byte before this field

### Header format

Each header is: `name_len (u8)` + `name (UTF-8)` + `type_byte (u8)` + `value`.

| Type atom    | Type byte | Wire value encoding                                 |
|:-------------|:---------:|:----------------------------------------------------|
| `:bool`      | 0 or 1    | no value bytes; `0` = true, `1` = false             |
| `:byte`      | 2         | 1 byte, signed                                      |
| `:short`     | 3         | 2 bytes, signed big-endian                          |
| `:integer`   | 4         | 4 bytes, signed big-endian                          |
| `:long`      | 5         | 8 bytes, signed big-endian                          |
| `:bytes`     | 6         | `len (u16)` + raw bytes                             |
| `:string`    | 7         | `len (u16)` + UTF-8 bytes                           |
| `:timestamp` | 8         | 8 bytes, signed big-endian milliseconds since epoch |
| `:uuid`      | 9         | 16 raw bytes                                        |

## Public modules

| Module                  | Purpose                                               |
|:------------------------|:------------------------------------------------------|
| `AWSEventStream`        | Facade: `encode/1`, `decode/1`, `decode/2`            |
| `AWSEventStream.Encoder`| Wire frame serialisation                              |
| `AWSEventStream.Decoder`| Incremental frame deserialisation with CRC validation |
| `AWSEventStream.Message`| `%Message{headers, payload}` struct + `header/2`      |
| `AWSEventStream.Header` | `%Header{name, type, value}` struct + wire codec      |
| `AWSEventStream.JSON`   | Optional JSON layer: classify + unwrap Bedrock frames |

## Status / Non-goals

**Status:** `0.2.0` — codec is complete and tested. 50 tests covering all header
types, encoder, decoder, round-trip property test, chunk-boundary splitting,
JSON classification, golden vectors captured from a live Bedrock stream, and the aws-sdk-go-v2 golden-vector corpus.

**Non-goals for this library:**

- **Corruption boundary scanning / recovery** — the decoder surfaces corrupt
  frames as tagged errors; re-synchronisation after corruption is left to the
  caller.
- **Service-specific payload helpers** — the codec understands the wire format;
  knowledge of any particular AWS service's event schema lives elsewhere.
- **Stream watcher / live capture tooling** — golden vectors are committed for
  regression; the capture tooling itself is out of scope.

## Upstream test vectors

`test/fixtures/aws_sdk_go_v2/` mirrors the event-stream test corpus from
[`aws/aws-sdk-go-v2`](https://github.com/aws/aws-sdk-go-v2/tree/main/aws/protocol/eventstream/testdata)
byte-for-byte; `manifest.json` pins the upstream commit. The suite decodes
every positive vector to the upstream-described message (and re-encodes it
byte-identically), and asserts each corrupted vector surfaces the documented
error.

Maintainers refresh the corpus with:

```sh
mix aws_event_stream.sync_fixtures   # exit 0 = up to date, 2 = fixtures updated
```

A weekly GitHub Actions workflow (`fixtures-watch.yml`) runs the same task and
opens an issue when the upstream corpus drifts, stating whether the codec still
passes against the new vectors.

**Future work:**

- Additional optional unwrapping patterns beyond the Bedrock `{"bytes": …}` envelope.
