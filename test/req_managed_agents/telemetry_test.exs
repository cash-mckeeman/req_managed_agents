defmodule ReqManagedAgents.TelemetryTest do
  use ExUnit.Case
  alias ReqManagedAgents.{Client, Stream}
  import ReqManagedAgents.SSEFixtures

  setup do
    bypass = Bypass.open()
    client = Client.new(api_key: "sk", base_url: "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass, client: client}
  end

  test "Client emits a request span", %{bypass: bypass, client: client} do
    test = self()

    :telemetry.attach_many(
      "t-req",
      [[:req_managed_agents, :request, :start], [:req_managed_agents, :request, :stop]],
      fn name, meas, meta, _ -> send(test, {:tel, name, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("t-req") end)

    Bypass.expect_once(bypass, "GET", "/v1/sessions/s1", fn conn ->
      Req.Test.json(conn, %{"id" => "s1"})
    end)

    {:ok, _} = Client.get_session(client, "s1")

    assert_receive {:tel, [:req_managed_agents, :request, :start], _,
                    %{method: :get, path: "/v1/sessions/s1"}}

    assert_receive {:tel, [:req_managed_agents, :request, :stop], %{duration: _}, %{status: 200}}
  end

  test "Stream emits connected + event + done, merging telemetry_metadata", %{
    bypass: bypass,
    client: client
  } do
    test = self()

    :telemetry.attach_many(
      "t-stream",
      [
        [:req_managed_agents, :stream, :connected],
        [:req_managed_agents, :stream, :event],
        [:req_managed_agents, :stream, :done]
      ],
      fn name, _meas, meta, _ -> send(test, {:tel, name, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("t-stream") end)

    Bypass.expect_once(bypass, "GET", "/v1/sessions/s1/events/stream", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, wire([end_turn()]))
      conn
    end)

    {:ok, _} =
      Task.start_link(fn ->
        Stream.stream(client, "s1", self(), ref: make_ref(), telemetry_metadata: %{tenant: "t1"})
      end)

    assert_receive {:tel, [:req_managed_agents, :stream, :connected],
                    %{session_id: "s1", tenant: "t1"}},
                   2000

    assert_receive {:tel, [:req_managed_agents, :stream, :event],
                    %{type: "session.status_idle", tenant: "t1"}},
                   2000

    assert_receive {:tel, [:req_managed_agents, :stream, :done], %{tenant: "t1"}}, 2000
  end
end
