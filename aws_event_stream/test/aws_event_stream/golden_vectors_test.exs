defmodule AWSEventStream.GoldenVectorsTest do
  use ExUnit.Case, async: true
  alias AWSEventStream.{Decoder, Encoder, Fixtures}

  test "each golden vector decodes to its expected message and re-encodes to the same bytes" do
    for %{name: name, hex: hex, message: message} <- Fixtures.golden_vectors() do
      bin = Base.decode16!(hex, case: :lower)
      assert {[{:ok, ^message}], <<>>} = Decoder.decode(bin), "decode mismatch: #{name}"
      assert IO.iodata_to_binary(Encoder.encode(message)) == bin, "encode mismatch: #{name}"
    end
  end

  test "the captured Bedrock exception frame decodes to an exception message" do
    {[{:ok, msg}], <<>>} = Decoder.decode(Fixtures.bedrock_exception_frame())
    assert AWSEventStream.Message.header(msg, ":message-type") == "exception"
    assert AWSEventStream.Message.header(msg, ":exception-type") == "throttlingException"
  end
end
