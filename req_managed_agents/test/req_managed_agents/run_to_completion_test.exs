defmodule ReqManagedAgents.RunToCompletionTest do
  use ExUnit.Case
  alias ReqManagedAgents.Client
  import ReqManagedAgents.SSEFixtures

  defmodule Echo do
    @behaviour ReqManagedAgents.Handler
    @impl true
    def handle_tool_call(_name, %{"q" => q}, _ctx), do: {:ok, "got #{q}"}
  end

  setup do
    bypass = Bypass.open()
    client = Client.new(api_key: "sk", base_url: "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass, client: client}
  end

  test "runs synchronously to end_turn and returns events", %{bypass: bypass, client: client} do
    Bypass.expect_once(bypass, "POST", "/v1/sessions", fn conn ->
      Req.Test.json(conn, %{"id" => "s1"})
    end)

    Bypass.expect_once(bypass, "GET", "/v1/sessions/s1/events/stream", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, wire([custom_tool_use("u1", "lookup", %{"q" => 5})]))
      {:ok, conn} = Plug.Conn.chunk(conn, wire([requires_action(["u1"])]))
      Process.sleep(200)
      {:ok, conn} = Plug.Conn.chunk(conn, wire([end_turn()]))
      conn
    end)

    Bypass.expect(bypass, "POST", "/v1/sessions/s1/events", fn conn ->
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert {:ok, %{terminal: :end_turn, events: events}} =
             ReqManagedAgents.run_to_completion(
               client: client,
               agent_id: "ag",
               environment_id: "env",
               prompt: "go",
               handler: Echo,
               timeout: 5000
             )

    assert Enum.any?(events, &(&1["type"] == "agent.custom_tool_use"))
  end

  test "returns {:error, :timeout} if no terminal arrives", %{bypass: bypass, client: client} do
    Bypass.expect_once(bypass, "POST", "/v1/sessions", fn conn ->
      Req.Test.json(conn, %{"id" => "s2"})
    end)

    Bypass.expect_once(bypass, "GET", "/v1/sessions/s2/events/stream", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)
      Process.sleep(400)
      conn
    end)

    Bypass.stub(bypass, "POST", "/v1/sessions/s2/events", fn conn ->
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert {:error, :timeout} =
             ReqManagedAgents.run_to_completion(
               client: client,
               agent_id: "ag",
               environment_id: "env",
               handler: Echo,
               timeout: 800
             )
  end
end
