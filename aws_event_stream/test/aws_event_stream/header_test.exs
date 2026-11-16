defmodule AWSEventStream.HeaderTest do
  use ExUnit.Case, async: true
  alias AWSEventStream.Header

  test "decodes a string header" do
    # name_len=11 ":event-type", type=7 string, len=5 "chunk"
    bin = <<11, ":event-type", 7, 0, 5, "chunk">>
    assert Header.decode_all(bin) == [%Header{name: ":event-type", type: :string, value: "chunk"}]
  end

  test "decodes bool true and bool false" do
    bin = <<1, "a", 0, 1, "b", 1>>

    assert Header.decode_all(bin) == [
             %Header{name: "a", type: :bool, value: true},
             %Header{name: "b", type: :bool, value: false}
           ]
  end

  test "decodes signed numeric types" do
    bin =
      <<1, "b", 2, -5::signed-8, 1, "s", 3, -300::signed-big-16, 1, "i", 4,
        -70_000::signed-big-32, 1, "l", 5, -5_000_000_000::signed-big-64>>

    assert Header.decode_all(bin) == [
             %Header{name: "b", type: :byte, value: -5},
             %Header{name: "s", type: :short, value: -300},
             %Header{name: "i", type: :integer, value: -70_000},
             %Header{name: "l", type: :long, value: -5_000_000_000}
           ]
  end

  test "decodes bytes, timestamp, and uuid" do
    uuid = :crypto.strong_rand_bytes(16)

    bin =
      <<1, "d", 6, 0, 3, "xyz", 1, "t", 8, 1_700_000_000_000::signed-big-64, 1, "u", 9,
        uuid::binary-16>>

    assert Header.decode_all(bin) == [
             %Header{name: "d", type: :bytes, value: "xyz"},
             %Header{
               name: "t",
               type: :timestamp,
               value: DateTime.from_unix!(1_700_000_000_000, :millisecond)
             },
             %Header{name: "u", type: :uuid, value: uuid}
           ]
  end

  test "empty blob decodes to empty list" do
    assert Header.decode_all(<<>>) == []
  end

  test "encodes a string header to the documented wire form" do
    h = %Header{name: ":event-type", type: :string, value: "chunk"}
    assert IO.iodata_to_binary(Header.encode(h)) == <<11, ":event-type", 7, 0, 5, "chunk">>
  end

  test "every type round-trips through encode |> decode_all" do
    uuid = :crypto.strong_rand_bytes(16)

    headers = [
      %Header{name: "bt", type: :bool, value: true},
      %Header{name: "bf", type: :bool, value: false},
      %Header{name: "by", type: :byte, value: -5},
      %Header{name: "sh", type: :short, value: -300},
      %Header{name: "in", type: :integer, value: -70_000},
      %Header{name: "lo", type: :long, value: -5_000_000_000},
      %Header{name: "da", type: :bytes, value: "xyz"},
      %Header{name: "st", type: :string, value: "hello"},
      %Header{
        name: "ts",
        type: :timestamp,
        value: DateTime.from_unix!(1_700_000_000_123, :millisecond)
      },
      %Header{name: "uu", type: :uuid, value: uuid}
    ]

    blob = headers |> Enum.map(&Header.encode/1) |> IO.iodata_to_binary()
    assert Header.decode_all(blob) == headers
  end
end
