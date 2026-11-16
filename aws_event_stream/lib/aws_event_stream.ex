defmodule AWSEventStream do
  @moduledoc """
  Codec for the AWS `vnd.amazon.eventstream` binary protocol.

  General-purpose and symmetric: `encode/1` serializes an
  `AWSEventStream.Message`; `decode/1,2` incrementally parses a byte buffer
  into `{results, rest}`. Payloads are opaque bytes — see `AWSEventStream.JSON`
  for the optional Bedrock/JSON convenience layer.
  """
  defdelegate encode(message), to: AWSEventStream.Encoder
  defdelegate decode(buffer), to: AWSEventStream.Decoder
  defdelegate decode(buffer, opts), to: AWSEventStream.Decoder
end
