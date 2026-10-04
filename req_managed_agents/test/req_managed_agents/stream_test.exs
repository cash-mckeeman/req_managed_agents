defmodule ReqManagedAgents.StreamTest do
  use ExUnit.Case
  alias ReqManagedAgents.{Client, Stream}
  import ReqManagedAgents.SSEFixtures

  setup do
    bypass = Bypass.open()
    client = Client.new(api_key: "sk-test", base_url: "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass, client: client}
  end

  test "delivers decoded events then :done to the subscriber", %{bypass: bypass, client: client} do
    parent = self()

    Bypass.expect_once(bypass, "GET", "/v1/sessions/s1/events/stream", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, wire([custom_tool_use("u1", "lookup", %{})]))
      {:ok, conn} = Plug.Conn.chunk(conn, wire([end_turn()]))
      conn
    end)

    ref = make_ref()

    {:ok, _task} =
      Task.start_link(fn ->
        Stream.stream(client, "s1", parent, ref: ref, finch: ReqManagedAgents.StreamFinch)
      end)

    assert_receive {:managed_agents, ^ref, :connected}, 2000

    assert_receive {:managed_agents, ^ref,
                    {:event, %{"type" => "agent.custom_tool_use", "id" => "u1"}}},
                   2000

    assert_receive {:managed_agents, ^ref, {:event, %{"type" => "session.status_idle"}}}, 2000
    assert_receive {:managed_agents, ^ref, :done}, 2000
  end

  test "reports a non-2xx status as an error", %{bypass: bypass, client: client} do
    parent = self()

    Bypass.expect_once(bypass, "GET", "/v1/sessions/s1/events/stream", fn conn ->
      Plug.Conn.resp(conn, 404, "nope")
    end)

    ref = make_ref()

    {:ok, _task} =
      Task.start_link(fn ->
        Stream.stream(client, "s1", parent, ref: ref, finch: ReqManagedAgents.StreamFinch)
      end)

    assert_receive {:managed_agents, ^ref, {:error, {:status, 404}}}, 2000
  end
end
