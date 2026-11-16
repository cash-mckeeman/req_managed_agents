defmodule AWSEventStream.ChunkBoundaryTest do
  use ExUnit.Case, async: true
  alias AWSEventStream.{Decoder, Encoder, Header, Message}

  defp feed(chunks) do
    {msgs, leftover} =
      Enum.reduce(chunks, {[], <<>>}, fn chunk, {acc, buf} ->
        {results, rest} = Decoder.decode(buf <> chunk)
        {acc ++ results, rest}
      end)

    {msgs, leftover}
  end

  test "any split point reassembles to the same messages" do
    a = %Message{headers: [%Header{name: ":event-type", type: :string, value: "a"}], payload: "1"}
    b = %Message{headers: [], payload: "second"}
    bin = IO.iodata_to_binary([Encoder.encode(a), Encoder.encode(b)])
    assert {[{:ok, ^a}, {:ok, ^b}], <<>>} = Decoder.decode(bin)

    for split <- 1..(byte_size(bin) - 1) do
      <<c1::binary-size(^split), c2::binary>> = bin
      assert feed([c1, c2]) == {[ok: a, ok: b], <<>>}
    end

    # byte-at-a-time
    chunks = for <<byte <- bin>>, do: <<byte>>
    assert feed(chunks) == {[ok: a, ok: b], <<>>}
  end
end
