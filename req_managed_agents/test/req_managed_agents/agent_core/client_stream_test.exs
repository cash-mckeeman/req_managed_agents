defmodule ReqManagedAgents.AgentCore.ClientStreamTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.AgentCore.Client
  import ReqManagedAgents.EventStreamFrames, only: [frame: 1]

  @creds %{
    access_key_id: "AKID",
    secret_access_key: "secret",
    region: "us-east-1",
    security_token: nil
  }

  @sid "test-session-id-long-enough-to-satisfy-min-length-33"
  @arn "arn:aws:bedrock-agentcore:us-east-1:123456789012:harness/ba"

  defp inv(extra \\ []) do
    Map.merge(
      %{
        harness_arn: @arn,
        runtime_session_id: @sid,
        messages: [%{"role" => "user", "content" => [%{"text" => "hi"}]}]
      },
      Map.new(extra)
    )
  end

  setup do
    bypass = Bypass.open()
    client = Client.new(credentials: @creds, base_url: "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass, client: client}
  end

  # Sends each binary in `chunks` with `gap_ms` sleep BEFORE each send.
  defp chunked(conn, chunks, gap_ms) do
    conn = Plug.Conn.send_chunked(conn, 200)

    Enum.reduce(chunks, conn, fn part, conn ->
      Process.sleep(gap_ms)

      case Plug.Conn.chunk(conn, part) do
        {:ok, conn} -> conn
        {:error, :closed} -> conn
      end
    end)
  end

  test "a turn longer than idle_timeout succeeds while chunks keep flowing", %{
    bypass: bypass,
    client: client
  } do
    # 6 gaps x 100ms = 600ms total > 400ms idle_timeout; each gap < 400ms.
    frames =
      Enum.map(1..5, fn i ->
        frame(~s({"contentBlockDelta":{"contentBlockIndex":0,"delta":{"text":"t#{i}"}}}))
      end) ++ [frame(~s({"messageStop":{"stopReason":"end_turn"}}))]

    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      chunked(conn, frames, 100)
    end)

    assert {:ok, events} = Client.invoke_harness(client, inv(idle_timeout: 400))
    assert %{"messageStop" => %{"stopReason" => "end_turn"}} = List.last(events)
    assert length(events) == 6
  end

  test "a stream that stalls beyond idle_timeout fails with a transport timeout", %{
    bypass: bypass,
    client: client
  } do
    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      {:ok, conn} =
        Plug.Conn.chunk(conn, frame(~s({"messageStart":{"role":"assistant"}})))

      # Stall past the client's idle timeout; the client must abandon the turn.
      Process.sleep(800)

      case Plug.Conn.chunk(conn, frame(~s({"messageStop":{"stopReason":"end_turn"}}))) do
        {:ok, conn} -> conn
        {:error, :closed} -> conn
      end
    end)

    assert {:error, %Req.TransportError{reason: :timeout}} =
             Client.invoke_harness(client, inv(idle_timeout: 300))

    # When the client disconnects mid-stream, Ranch/Cowboy kills the connection
    # handler process with :shutdown. Bypass monitors that process and would
    # re-raise the exit in on_exit. Bypass.pass/1 sets pass: true so on_exit
    # returns :ok regardless of the handler exit reason.
    Bypass.pass(bypass)
  end

  test "a frame split across chunk boundaries decodes without loss or duplication", %{
    bypass: bypass,
    client: client
  } do
    stop = frame(~s({"messageStop":{"stopReason":"end_turn"}}))
    start_frame = frame(~s({"messageStart":{"role":"assistant"}}))
    # Split the second frame mid-prelude.
    <<head::binary-size(5), tail::binary>> = stop

    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      chunked(conn, [start_frame, head, tail], 20)
    end)

    assert {:ok,
            [
              %{"messageStart" => %{"role" => "assistant"}},
              %{"messageStop" => %{"stopReason" => "end_turn"}}
            ]} = Client.invoke_harness(client, inv())
  end

  test "non-2xx responses still surface {:error, {:http_error, status, body}}", %{
    bypass: bypass,
    client: client
  } do
    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(429, ~s({"message":"Too many requests"}))
    end)

    assert {:error, {:http_error, 429, body}} = Client.invoke_harness(client, inv())
    assert body =~ "Too many requests"
  end

  test "on_event fires once per decoded event, in order, before invoke returns", %{
    bypass: bypass,
    client: client
  } do
    frames = [
      frame(~s({"messageStart":{"role":"assistant"}})),
      frame(~s({"contentBlockDelta":{"contentBlockIndex":0,"delta":{"text":"hello"}}})),
      frame(~s({"messageStop":{"stopReason":"end_turn"}}))
    ]

    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      chunked(conn, frames, 10)
    end)

    test_pid = self()

    assert {:ok, events} =
             Client.invoke_harness(
               client,
               inv(on_event: fn ev -> send(test_pid, {:ev, ev}) end)
             )

    # All on_event sends happened before invoke_harness returned -> already in our mailbox.
    received =
      for _ <- 1..3 do
        assert_received {:ev, ev}
        ev
      end

    assert received == events
    refute_received {:ev, _}
  end

  test "on_event is optional — omitting it changes nothing", %{bypass: bypass, client: client} do
    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      chunked(conn, [frame(~s({"messageStop":{"stopReason":"end_turn"}}))], 10)
    end)

    assert {:ok, [%{"messageStop" => _}]} = Client.invoke_harness(client, inv())
  end

  test "budget knobs serialize as timeoutSeconds/maxIterations/maxTokens", %{
    bypass: bypass,
    client: client
  } do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})
      chunked(conn, [frame(~s({"messageStop":{"stopReason":"end_turn"}}))], 10)
    end)

    assert {:ok, _} =
             Client.invoke_harness(
               client,
               inv(timeout_seconds: 900, max_iterations: 40, max_tokens: 4096)
             )

    assert_received {:body, body}
    assert body["timeoutSeconds"] == 900
    assert body["maxIterations"] == 40
    assert body["maxTokens"] == 4096
  end

  test "budget knobs are absent from the body by default (harness defaults rule)", %{
    bypass: bypass,
    client: client
  } do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/harnesses/invoke", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})
      chunked(conn, [frame(~s({"messageStop":{"stopReason":"end_turn"}}))], 10)
    end)

    assert {:ok, _} = Client.invoke_harness(client, inv())

    assert_received {:body, body}
    refute Map.has_key?(body, "timeoutSeconds")
    refute Map.has_key?(body, "maxIterations")
    refute Map.has_key?(body, "maxTokens")
  end
end
