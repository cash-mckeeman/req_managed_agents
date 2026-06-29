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

  test ":event-type header wraps the unwrapped payload under the event-type key" do
    # The real AgentCore Converse stream delivers UNWRAPPED payloads — the outer
    # event-type key is NOT in the JSON body; it lives in the frame's :event-type
    # header. decode/1 must wrap each payload as %{event_type => payload} so that
    # Converse.parse/1 sees the expected envelope shape.
    headers_bin = str_header(":event-type", "contentBlockStart")
    payload = ~s({"contentBlockIndex":0,"start":{"toolUse":{"toolUseId":"t1","name":"echo"}}})
    f = frame_with_headers(headers_bin, payload)
    assert {[msg], ""} = EventStream.decode(f)
    # The outer key is the event type from the header; value is the unwrapped payload.
    assert Map.keys(msg) == ["contentBlockStart"]
    assert get_in(msg, ["contentBlockStart", "start", "toolUse", "name"]) == "echo"
  end

  test ":message-type exception frame is surfaced as a tagged __stream_error__ map" do
    # A real AgentCore early-termination frame (confirmed live, MIM-52 spike):
    # :message-type "exception", :exception-type "runtimeClientError", NO :event-type,
    # body {"message":"...ValidationException...duplicate Ids..."}. Without surfacing,
    # this falls through as a shapeless map → no stop_reason → silent :terminated/nil.
    headers_bin =
      str_header(":message-type", "exception") <>
        str_header(":exception-type", "runtimeClientError")

    f = frame_with_headers(headers_bin, ~s({"message":"duplicate Ids"}))

    assert {[event], ""} = EventStream.decode(f)

    assert event == %{
             "__stream_error__" => %{
               "type" => "runtimeClientError",
               "message" => %{"message" => "duplicate Ids"}
             }
           }
  end

  test "frame with :event-type header — payload type in header, not in body" do
    # Second example: contentBlockDelta — payload has no outer event-type wrapper.
    headers_bin = str_header(":event-type", "contentBlockDelta")
    payload = ~s({"contentBlockIndex":0,"delta":{"text":"hello"}})
    f = frame_with_headers(headers_bin, payload)
    assert {[msg], ""} = EventStream.decode(f)
    assert Map.keys(msg) == ["contentBlockDelta"]
    assert get_in(msg, ["contentBlockDelta", "delta", "text"]) == "hello"
  end

  test "frame without :event-type header passes payload through unwrapped (exception / legacy)" do
    # Frames that carry no :event-type header (e.g. :exception-type frames, or
    # zero-header frames) pass through as-is — the JSON payload is returned directly.
    headers_bin = str_header(":exception-type", "ValidationException")
    payload = ~s({"message":"bad input"})
    f = frame_with_headers(headers_bin, payload)
    assert {[msg], ""} = EventStream.decode(f)
    # No wrapping — exception frames pass through as-is.
    assert msg["message"] == "bad input"
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
