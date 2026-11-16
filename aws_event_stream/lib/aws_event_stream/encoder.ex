defmodule AWSEventStream.Encoder do
  @moduledoc "Encodes `AWSEventStream.Message` structs into `vnd.amazon.eventstream` frames."
  alias AWSEventStream.{Header, Message}

  @prelude_size 12
  @crc_size 4

  @doc "Encode a message into a complete frame as iodata."
  @spec encode(Message.t()) :: iodata()
  def encode(%Message{headers: headers, payload: payload}) do
    headers_bin = headers |> Enum.map(&Header.encode/1) |> IO.iodata_to_binary()
    headers_len = byte_size(headers_bin)
    total_len = @prelude_size + headers_len + byte_size(payload) + @crc_size

    prelude = <<total_len::big-32, headers_len::big-32>>
    prelude_crc = :erlang.crc32(prelude)

    without_msg_crc =
      <<prelude::binary, prelude_crc::big-32, headers_bin::binary, payload::binary>>

    msg_crc = :erlang.crc32(without_msg_crc)

    [without_msg_crc, <<msg_crc::big-32>>]
  end
end
