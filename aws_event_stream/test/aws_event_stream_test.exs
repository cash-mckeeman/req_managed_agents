defmodule AWSEventStreamTest do
  use ExUnit.Case, async: true
  alias AWSEventStream.{Header, Message}

  test "facade encode/decode round-trips" do
    msg = %Message{headers: [%Header{name: ":x", type: :string, value: "y"}], payload: "z"}
    bin = IO.iodata_to_binary(AWSEventStream.encode(msg))
    assert {[{:ok, ^msg}], <<>>} = AWSEventStream.decode(bin)
  end
end
