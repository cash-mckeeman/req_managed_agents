defmodule AWSEventStream.SDKVectorsTest do
  @moduledoc """
  Interoperability against the corpus AWS itself tests with, synced from
  aws-sdk-go-v2 by `mix aws_event_stream.sync_fixtures`.
  """
  use ExUnit.Case, async: true
  alias AWSEventStream.{Decoder, Encoder, Fixtures}

  test "the SDK corpus is present and non-empty" do
    assert File.dir?(Fixtures.sdk_corpus_dir()),
           "missing #{Fixtures.sdk_corpus_dir()} — run `mix aws_event_stream.sync_fixtures`"

    refute Fixtures.sdk_cases(:positive) == [], "no positive cases in the corpus"
    refute Fixtures.sdk_cases(:negative) == [], "no negative cases in the corpus"
  end

  test "each positive vector decodes to the upstream-described message and re-encodes byte-identically" do
    for %{name: name, encoded: frame, decoded: json_bin} <- Fixtures.sdk_cases(:positive) do
      json = Jason.decode!(json_bin)
      expected = Fixtures.message_from_json(json)

      assert {[{:ok, ^expected}], <<>>} = Decoder.decode(frame), "decode mismatch: #{name}"
      assert IO.iodata_to_binary(Encoder.encode(expected)) == frame, "encode mismatch: #{name}"

      # the JSON's frame metadata agrees with the actual bytes
      assert byte_size(frame) == json["total_length"], "total_length mismatch: #{name}"
      <<_total::big-32, hlen::big-32, pcrc::big-32, _::binary>> = frame
      <<mcrc::big-32>> = binary_part(frame, byte_size(frame) - 4, 4)
      assert hlen == json["headers_length"], "headers_length mismatch: #{name}"
      assert pcrc == Fixtures.unsigned32(json["prelude_crc"]), "prelude_crc mismatch: #{name}"
      assert mcrc == Fixtures.unsigned32(json["message_crc"]), "message_crc mismatch: #{name}"
    end
  end

  test "each negative vector surfaces the upstream-described error" do
    for %{name: name, encoded: frame, decoded: prose} <- Fixtures.sdk_cases(:negative) do
      expected = Fixtures.expected_error_atom(prose)

      assert {[{:error, {^expected, _raw}}], _rest} = Decoder.decode(frame),
             "error mismatch: #{name}"
    end
  end
end
