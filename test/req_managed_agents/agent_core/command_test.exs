defmodule ReqManagedAgents.AgentCore.CommandTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.AgentCore.{Client, CommandResult}
  import ReqManagedAgents.EventStreamFrames, only: [frame: 1]

  @creds %{
    access_key_id: "AKID",
    secret_access_key: "secret",
    region: "us-east-1",
    security_token: nil
  }

  @arn "arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/ba-x1"
  @sid "test-session-id-long-enough-to-satisfy-min-length-33"

  defp inv(extra \\ []) do
    Map.merge(
      %{agent_runtime_arn: @arn, runtime_session_id: @sid, command: "echo hi"},
      Map.new(extra)
    )
  end

  setup do
    bypass = Bypass.open()
    client = Client.new(credentials: @creds, base_url: "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass, client: client}
  end

  defp chunked(conn, frames) do
    conn = Plug.Conn.send_chunked(conn, 200)

    Enum.reduce(frames, conn, fn part, conn ->
      case Plug.Conn.chunk(conn, part) do
        {:ok, conn} -> conn
        {:error, :closed} -> conn
      end
    end)
  end

  test "collects stdout/stderr/exitCode from chunk-wrapped events; ARN rides the path; session header set",
       %{bypass: bypass, client: client} do
    Bypass.expect_once(bypass, fn conn ->
      # Catch-all route: the path embeds the percent-encoded ARN, so we assert on it here.
      assert conn.method == "POST"
      assert conn.request_path =~ "/runtimes/"
      assert conn.request_path =~ "/commands"
      assert conn.request_path =~ "runtime%2Fba-x1" or conn.request_path =~ "runtime/ba-x1"

      assert {_, @sid} =
               Enum.find(conn.req_headers, fn {k, _} ->
                 k == "x-amzn-bedrock-agentcore-runtime-session-id"
               end)

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"command" => "echo hi"} = Jason.decode!(body)

      chunked(conn, [
        frame(~s({"chunk":{"contentStart":{}}})),
        frame(~s({"chunk":{"contentDelta":{"stdout":"hi"}}})),
        frame(~s({"chunk":{"contentDelta":{"stderr":"warn"}}})),
        frame(~s({"chunk":{"contentDelta":{"stdout":"!\\n"}}})),
        frame(~s({"chunk":{"contentStop":{"exitCode":0,"status":"completed"}}}))
      ])
    end)

    assert {:ok, %CommandResult{stdout: "hi!\n", stderr: "warn", exit_code: 0}} =
             Client.invoke_agent_runtime_command(client, inv())
  end

  test "bare (unwrapped) events are tolerated; non-zero exit is NOT an error", %{
    bypass: bypass,
    client: client
  } do
    Bypass.expect_once(bypass, fn conn ->
      assert conn.method == "POST"

      chunked(conn, [
        frame(~s({"contentDelta":{"stderr":"boom"}})),
        frame(~s({"contentStop":{"exitCode":3,"status":"completed"}}))
      ])
    end)

    assert {:ok, %CommandResult{stderr: "boom", exit_code: 3}} =
             Client.invoke_agent_runtime_command(client, inv())
  end

  test "on_output streams labeled chunks in order before return; timeout_seconds serializes", %{
    bypass: bypass,
    client: client
  } do
    test_pid = self()

    Bypass.expect_once(bypass, fn conn ->
      assert conn.method == "POST"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"timeout" => 120} = Jason.decode!(body)

      chunked(conn, [
        frame(~s({"chunk":{"contentDelta":{"stdout":"a"}}})),
        frame(~s({"chunk":{"contentDelta":{"stderr":"b"}}})),
        frame(~s({"chunk":{"contentStop":{"exitCode":0,"status":"completed"}}}))
      ])
    end)

    assert {:ok, _} =
             Client.invoke_agent_runtime_command(
               client,
               inv(
                 timeout_seconds: 120,
                 on_output: fn stream, chunk -> send(test_pid, {:out, stream, chunk}) end
               )
             )

    assert_received {:out, :stdout, "a"}
    assert_received {:out, :stderr, "b"}
  end

  test "a stalled stream fails with a transport timeout at idle_timeout", %{
    bypass: bypass,
    client: client
  } do
    Bypass.expect_once(bypass, fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, frame(~s({"chunk":{"contentStart":{}}})))
      Process.sleep(800)

      case Plug.Conn.chunk(conn, frame(~s({"chunk":{"contentStop":{"exitCode":0}}}))) do
        {:ok, conn} -> conn
        {:error, :closed} -> conn
      end
    end)

    assert {:error, %Req.TransportError{reason: :timeout}} =
             Client.invoke_agent_runtime_command(client, inv(idle_timeout: 300))

    Bypass.pass(bypass)
  end

  test "an exception frame surfaces as an error", %{bypass: bypass, client: client} do
    Bypass.expect_once(bypass, fn conn ->
      chunked(conn, [
        frame(~s({"__stream_error__":{"type":"validationException","message":{"message":"bad"}}}))
      ])
    end)

    assert {:error, {:command_stream_error, "validationException", _}} =
             Client.invoke_agent_runtime_command(client, inv())
  end
end
