defmodule ReqManagedAgents.AgentCore.EventStreamTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.AgentCore.EventStream

  # Build one well-formed vnd.amazon.eventstream frame carrying a JSON payload.
  defp frame(payload_json) do
    headers = <<>>
    payload = payload_json
    prelude = <<12 + byte_size(headers) + byte_size(payload) + 4::32, byte_size(headers)::32>>
    prelude_crc = :erlang.crc32(prelude)
    body = prelude <> <<prelude_crc::32>> <> headers <> payload
    message_crc = :erlang.crc32(body)
    body <> <<message_crc::32>>
  end

  # Build a string header in the AWS Event Stream wire format:
  # name-len(1B) + name + value-type(1B=7 for string) + value-len(2B big-endian) + value
  defp str_header(name, value) do
    <<byte_size(name)::8, name::binary, 7::8, byte_size(value)::big-16, value::binary>>
  end

  # Build a frame with non-empty headers.
  defp frame_with_headers(headers_bin, payload_json) do
    payload = payload_json
    total_len = 12 + byte_size(headers_bin) + byte_size(payload) + 4
    prelude = <<total_len::32, byte_size(headers_bin)::32>>
    prelude_crc = :erlang.crc32(prelude)
    body = prelude <> <<prelude_crc::32>> <> headers_bin <> payload
    message_crc = :erlang.crc32(body)
    body <> <<message_crc::32>>
  end

  test "decodes a single complete frame into its JSON payload map" do
    f = frame(~s({"contentBlockStart":{"start":{"toolUse":{"toolUseId":"t1","name":"echo"}}}}))
    assert {[msg], ""} = EventStream.decode(f)
    assert get_in(msg, ["contentBlockStart", "start", "toolUse", "name"]) == "echo"
  end

  test "returns the trailing partial bytes as remainder for the next chunk" do
    f = frame(~s({"messageStop":{"stopReason":"tool_use"}}))
    {head, tail} = :erlang.split_binary(f, byte_size(f) - 5)
    assert {[], ^head} = EventStream.decode(head)
    assert {[msg], ""} = EventStream.decode(head <> tail)
    assert get_in(msg, ["messageStop", "stopReason"]) == "tool_use"
  end

  test "skips non-empty headers and decodes payload correctly (proves header-parsing port)" do
    # Build a frame with a real :event-type string header (type 7 per AWS wire format).
    # The binary-pattern slices headers_len bytes for headers regardless of content,
    # and parse_headers/1 (ported from req_llm) correctly walks name/type/value triples.
    headers_bin = str_header(":event-type", "contentBlockDelta")
    payload = ~s({"type":"contentBlockDelta","delta":{"text":"hello"}})
    f = frame_with_headers(headers_bin, payload)
    assert {[msg], ""} = EventStream.decode(f)
    assert msg["type"] == "contentBlockDelta"
    assert get_in(msg, ["delta", "text"]) == "hello"
  end

  test "drops frame with corrupted message CRC (no decoded message returned)" do
    # Build a well-formed frame, then corrupt only the trailing 4-byte message CRC.
    # The decoder must consume the frame's bytes (advancing past it) but drop it from
    # the result — matching the prelude-CRC-mismatch drop posture from req_llm.
    f = frame(~s({"ok":true}))
    frame_body = binary_part(f, 0, byte_size(f) - 4)
    corrupted = frame_body <> <<0xDEADBEEF::32>>
    assert {[], ""} = EventStream.decode(corrupted)
  end
end
