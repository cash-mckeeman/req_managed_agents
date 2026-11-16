defmodule AWSEventStream.RoundtripTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias AWSEventStream.{Decoder, Encoder, Header, Message}

  defp header_gen do
    name = string(:alphanumeric, min_length: 1, max_length: 40)

    one_of([
      gen(all(n <- name, v <- boolean(), do: %Header{name: n, type: :bool, value: v})),
      gen(all(n <- name, v <- integer(-128..127), do: %Header{name: n, type: :byte, value: v})),
      gen(
        all(
          n <- name,
          v <- integer(-32_768..32_767),
          do: %Header{name: n, type: :short, value: v}
        )
      ),
      gen(
        all(
          n <- name,
          v <- integer(-2_147_483_648..2_147_483_647),
          do: %Header{name: n, type: :integer, value: v}
        )
      ),
      gen(
        all(
          n <- name,
          v <- integer(-9_223_372_036_854_775_808..9_223_372_036_854_775_807),
          do: %Header{name: n, type: :long, value: v}
        )
      ),
      gen(all(n <- name, v <- binary(), do: %Header{name: n, type: :bytes, value: v})),
      gen(all(n <- name, v <- string(:utf8), do: %Header{name: n, type: :string, value: v})),
      gen(
        all(
          n <- name,
          ms <- integer(0..2_000_000_000_000),
          do: %Header{name: n, type: :timestamp, value: DateTime.from_unix!(ms, :millisecond)}
        )
      ),
      gen(all(n <- name, v <- binary(length: 16), do: %Header{name: n, type: :uuid, value: v}))
    ])
  end

  property "decode(encode(msg)) == msg for arbitrary messages" do
    check all(headers <- list_of(header_gen(), max_length: 8), payload <- binary()) do
      msg = %Message{headers: headers, payload: payload}
      bin = IO.iodata_to_binary(Encoder.encode(msg))
      assert Decoder.decode(bin) == {[{:ok, msg}], <<>>}
    end
  end
end
