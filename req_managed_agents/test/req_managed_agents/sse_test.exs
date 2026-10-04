defmodule ReqManagedAgents.SSETest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.SSE

  test "decodes a single complete frame and returns empty remainder" do
    buf = ~s(event: agent.message\ndata: {"type":"agent.message","id":"e1"}\n\n)
    assert {[%{"type" => "agent.message", "id" => "e1"}], ""} = SSE.decode(buf)
  end

  test "decodes multiple frames in one buffer" do
    buf =
      ~s(data: {"type":"a","id":"1"}\n\n) <>
        ~s(data: {"type":"b","id":"2"}\n\n)

    assert {[%{"type" => "a"}, %{"type" => "b"}], ""} = SSE.decode(buf)
  end

  test "keeps a trailing partial frame in the remainder" do
    buf = ~s(data: {"type":"a","id":"1"}\n\ndata: {"type":"b")
    assert {[%{"type" => "a"}], ~s(data: {"type":"b")} = SSE.decode(buf)
  end

  test "tolerates CRLF separators" do
    buf = "data: {\"type\":\"a\",\"id\":\"1\"}\r\n\r\n"
    assert {[%{"type" => "a"}], ""} = SSE.decode(buf)
  end

  test "joins multi-line data fields" do
    buf = ~s(data: {"type":"a",\ndata: "id":"1"}\n\n)
    assert {[%{"type" => "a", "id" => "1"}], ""} = SSE.decode(buf)
  end

  test "ignores comment/heartbeat lines and frames with no data" do
    buf = ~s(: heartbeat\n\ndata: {"type":"a","id":"1"}\n\n)
    assert {[%{"type" => "a"}], ""} = SSE.decode(buf)
  end

  test "skips undecodable JSON without crashing" do
    buf = ~s(data: not-json\n\ndata: {"type":"a","id":"1"}\n\n)
    assert {[%{"type" => "a"}], ""} = SSE.decode(buf)
  end
end
