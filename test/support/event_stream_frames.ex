defmodule ReqManagedAgents.EventStreamFrames do
  @moduledoc false
  # Minimal vnd.amazon.eventstream encoder for tests: a headerless frame whose
  # JSON payload passes through EventStream.decode/1 as the envelope itself
  # (no :event-type header -> payload emitted as-is).
  def frame(payload) when is_binary(payload) do
    headers = <<>>
    prelude = <<12 + byte_size(headers) + byte_size(payload) + 4::32, byte_size(headers)::32>>
    signed = prelude <> <<:erlang.crc32(prelude)::32>> <> headers <> payload
    signed <> <<:erlang.crc32(signed)::32>>
  end
end
