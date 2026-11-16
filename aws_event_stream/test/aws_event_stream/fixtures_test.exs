defmodule AWSEventStream.FixturesTest do
  use ExUnit.Case, async: true
  alias AWSEventStream.{Fixtures, Header, Message}

  test "message_from_json maps every header type byte and base64 field" do
    json = %{
      "headers" => [
        %{"name" => "t", "type" => 0, "value" => true},
        %{"name" => "f", "type" => 1, "value" => false},
        %{"name" => "byte", "type" => 2, "value" => -49},
        %{"name" => "short", "type" => 3, "value" => 42},
        %{"name" => "int", "type" => 4, "value" => 40_972},
        %{"name" => "long", "type" => 5, "value" => 42_424_242},
        %{"name" => "buf", "type" => 6, "value" => Base.encode64("raw")},
        %{"name" => "str", "type" => 7, "value" => Base.encode64("application/json")},
        %{"name" => "ts", "type" => 8, "value" => 8_675_309},
        %{"name" => "uuid", "type" => 9, "value" => Base.encode64(<<1::128>>)}
      ],
      "payload" => Base.encode64("{'foo':'bar'}")
    }

    assert %Message{headers: headers, payload: "{'foo':'bar'}"} = Fixtures.message_from_json(json)

    assert headers == [
             %Header{name: "t", type: :bool, value: true},
             %Header{name: "f", type: :bool, value: false},
             %Header{name: "byte", type: :byte, value: -49},
             %Header{name: "short", type: :short, value: 42},
             %Header{name: "int", type: :integer, value: 40_972},
             %Header{name: "long", type: :long, value: 42_424_242},
             %Header{name: "buf", type: :bytes, value: "raw"},
             %Header{name: "str", type: :string, value: "application/json"},
             %Header{
               name: "ts",
               type: :timestamp,
               value: DateTime.from_unix!(8_675_309, :millisecond)
             },
             %Header{name: "uuid", type: :uuid, value: <<1::128>>}
           ]
  end

  test "message_from_json tolerates absent headers/payload (empty message)" do
    assert Fixtures.message_from_json(%{}) == %Message{headers: [], payload: ""}
  end

  test "expected_error_atom maps the known upstream descriptions" do
    assert Fixtures.expected_error_atom("Prelude checksum mismatch") == :invalid_prelude_crc
    assert Fixtures.expected_error_atom("Message checksum mismatch\n") == :invalid_message_crc
  end

  test "expected_error_atom raises loudly on unmapped prose" do
    assert_raise RuntimeError, ~r/unmapped upstream error description.*Frame too big/s, fn ->
      Fixtures.expected_error_atom("Frame too big")
    end
  end

  test "unsigned32 normalizes Go's signed int32 serialization" do
    assert Fixtures.unsigned32(-1_415_188_212) == 2_879_779_084
    assert Fixtures.unsigned32(263_087_306) == 263_087_306
  end
end
