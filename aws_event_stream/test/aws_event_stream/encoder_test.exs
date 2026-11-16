defmodule AWSEventStream.EncoderTest do
  use ExUnit.Case, async: true
  alias AWSEventStream.{Encoder, Header, Message}

  test "encodes a frame with correct lengths and CRCs" do
    msg = %Message{headers: [%Header{name: ":x", type: :string, value: "y"}], payload: "{}"}
    bin = IO.iodata_to_binary(Encoder.encode(msg))

    <<total::big-32, hlen::big-32, pcrc::big-32, rest::binary>> = bin
    assert total == byte_size(bin)
    assert :erlang.crc32(<<total::big-32, hlen::big-32>>) == pcrc

    <<body::binary-size(^total - 12 - 4), mcrc::big-32>> = rest
    assert byte_size(body) == hlen + 2
    assert :erlang.crc32(binary_part(bin, 0, total - 4)) == mcrc
  end

  test "Message.header/2 returns the first matching value or nil" do
    msg = %Message{headers: [%Header{name: ":message-type", type: :string, value: "event"}]}
    assert Message.header(msg, ":message-type") == "event"
    assert Message.header(msg, ":missing") == nil
  end
end
