defmodule AWSEventStream.JSONTest do
  use ExUnit.Case, async: true
  alias AWSEventStream.{Header, JSON, Message}

  defp msg(headers, payload), do: %Message{headers: headers, payload: payload}
  defp h(name, value), do: %Header{name: name, type: :string, value: value}

  test "classifies an event frame, unwrapping direct JSON" do
    m =
      msg(
        [h(":message-type", "event"), h(":event-type", "contentBlockDelta")],
        ~s({"delta":{"text":"hi"}})
      )

    assert JSON.classify(m) == {:event, "contentBlockDelta", %{"delta" => %{"text" => "hi"}}}
  end

  test "classifies an event frame, unwrapping {\"bytes\": base64} payloads" do
    inner = Base.encode64(~s({"k":1}))
    m = msg([h(":message-type", "event"), h(":event-type", "chunk")], ~s({"bytes":"#{inner}"}))
    assert JSON.classify(m) == {:event, "chunk", %{"k" => 1}}
  end

  test "classifies an exception frame by :message-type before :event-type" do
    m =
      msg(
        [h(":message-type", "exception"), h(":exception-type", "throttlingException")],
        ~s({"message":"Rate exceeded"})
      )

    assert JSON.classify(m) ==
             {:exception, "throttlingException", %{"message" => "Rate exceeded"}}
  end

  test "classifies an internal error frame from headers" do
    m =
      msg(
        [
          h(":message-type", "error"),
          h(":error-code", "InternalFailure"),
          h(":error-message", "boom")
        ],
        ""
      )

    assert JSON.classify(m) == {:error, "InternalFailure", "boom"}
  end

  test "surfaces malformed JSON distinctly (no :error collision)" do
    m = msg([h(":message-type", "event"), h(":event-type", "chunk")], "not json")
    assert {:malformed_payload, ^m, _reason} = JSON.classify(m)
  end

  test "decode/1 re-tags core frame errors as :malformed_frame" do
    good =
      IO.iodata_to_binary(
        AWSEventStream.encode(msg([h(":message-type", "event"), h(":event-type", "chunk")], "{}"))
      )

    corrupt = binary_part(good, 0, byte_size(good) - 1) <> <<0>>
    assert {[{:malformed_frame, :invalid_message_crc, ^corrupt}], <<>>} = JSON.decode(corrupt)
  end

  test "an exception frame that ALSO carries :event-type is still classified as exception" do
    m =
      msg(
        [
          h(":message-type", "exception"),
          h(":event-type", "contentBlockDelta"),
          h(":exception-type", "throttlingException")
        ],
        ~s({"message":"Rate exceeded"})
      )

    assert JSON.classify(m) ==
             {:exception, "throttlingException", %{"message" => "Rate exceeded"}}
  end

  test "an event frame whose bytes payload is not valid base64 surfaces :invalid_base64" do
    m =
      msg(
        [h(":message-type", "event"), h(":event-type", "chunk")],
        ~s({"bytes":"not valid base64 !!!"})
      )

    assert {:malformed_payload, ^m, :invalid_base64} = JSON.classify(m)
  end

  test "an exception frame with a non-JSON body still classifies as :exception, raw body preserved" do
    m =
      msg(
        [h(":message-type", "exception"), h(":exception-type", "throttlingException")],
        "not json"
      )

    assert JSON.classify(m) == {:exception, "throttlingException", %{"raw" => "not json"}}
  end

  test "an exception frame with an empty body still classifies as :exception" do
    m = msg([h(":message-type", "exception"), h(":exception-type", "ValidationException")], "")
    assert JSON.classify(m) == {:exception, "ValidationException", %{"raw" => ""}}
  end

  test "an error frame with an empty body still classifies as :error from headers" do
    m =
      msg(
        [
          h(":message-type", "error"),
          h(":error-code", "InternalFailure"),
          h(":error-message", "boom")
        ],
        ""
      )

    assert JSON.classify(m) == {:error, "InternalFailure", "boom"}
  end
end
