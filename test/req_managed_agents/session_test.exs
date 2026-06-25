defmodule ReqManagedAgents.SessionTest do
  use ExUnit.Case
  alias ReqManagedAgents.{Client, Session}
  import ReqManagedAgents.SSEFixtures

  defmodule EchoHandler do
    @behaviour ReqManagedAgents.Handler
    @impl true
    def handle_tool_call(name, input, %{test_pid: pid}) do
      send(pid, {:tool_called, name, input})
      {:ok, "echo:#{name}"}
    end

    @impl true
    def handle_event(%{"type" => type}, %{test_pid: pid}) do
      send(pid, {:event_seen, type})
      :ok
    end
  end

  setup do
    bypass = Bypass.open()
    client = Client.new(api_key: "sk-test", base_url: "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass, client: client}
  end

  test "runs the requires_action -> custom_tool_result -> end_turn cycle", %{
    bypass: bypass,
    client: client
  } do
    parent = self()

    # create_session
    Bypass.expect_once(bypass, "POST", "/v1/sessions", fn conn ->
      Req.Test.json(conn, %{"id" => "s1", "status" => "running"})
    end)

    # the stream: one tool-use, then requires_action, then end_turn
    Bypass.expect_once(bypass, "GET", "/v1/sessions/s1/events/stream", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, wire([custom_tool_use("u1", "lookup", %{"q" => 1})]))
      {:ok, conn} = Plug.Conn.chunk(conn, wire([requires_action(["u1"])]))
      # give the session time to post the tool result before ending the turn
      Process.sleep(200)
      {:ok, conn} = Plug.Conn.chunk(conn, wire([end_turn()]))
      conn
    end)

    # the tool result POST back
    Bypass.expect_once(bypass, "POST", "/v1/sessions/s1/events", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      send(parent, {:posted, decoded})
      Req.Test.json(conn, %{"ok" => true})
    end)

    {:ok, _pid} =
      Session.start_link(
        client: client,
        agent_id: "agent_1",
        prompt: "go",
        handler: EchoHandler,
        context: %{test_pid: parent},
        notify: parent
      )

    assert_receive {:tool_called, "lookup", %{"q" => 1}}, 3000

    assert_receive {:posted,
                    %{
                      "events" => [
                        %{
                          "type" => "user.custom_tool_result",
                          "custom_tool_use_id" => "u1",
                          "is_error" => false
                        }
                      ]
                    }},
                   3000

    assert_receive {:managed_agents_session, :end_turn}, 3000
  end
end
