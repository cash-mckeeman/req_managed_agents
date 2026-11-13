defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.ReconnectMetadataTest do
  use ExUnit.Case, async: false
  alias ReqManagedAgents.Providers.ClaudeManagedAgents

  test "a fresh session keeps its telemetry metadata after a reconnect", do: exercise(:fresh)

  test "a reattached session keeps its telemetry metadata after a reconnect",
    do: exercise(:reattach)

  defp exercise(mode) do
    server = Bypass.open()
    Bypass.stub(server, "POST", "/v1/sessions", &Req.Test.json(&1, %{id: "correlated-session"}))

    Bypass.stub(
      server,
      "GET",
      "/v1/sessions/correlated-session/events",
      &Req.Test.json(&1, %{data: [], has_more: false})
    )

    Bypass.stub(
      server,
      "GET",
      "/v1/sessions/correlated-session/events/stream",
      &Plug.Conn.send_chunked(&1, 200)
    )

    metadata = %{tenant: "t1", step_id: "step-2"}
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:req_managed_agents, :stream, :connected],
      fn _, _, meta, owner -> send(owner, {:connected, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    opts = [
      model_config: %{api_key: "test-key", base_url: "http://localhost:#{server.port}"},
      telemetry_metadata: metadata,
      agent_id: "agent",
      environment_id: "env"
    ]

    opts =
      if mode == :reattach, do: Keyword.put(opts, :session_id, "correlated-session"), else: opts

    assert {:ok, conn} = ClaudeManagedAgents.open(opts, self())
    if mode == :fresh, do: assert_receive({:connected, %{tenant: "t1"}}, 1000)

    # The Session hands each reconnect's conn to the next, so a second
    # reconnect proves the returned conn still carries the metadata.
    Enum.reduce(1..2, conn, fn _, conn ->
      assert {:ok, conn, _, _, _} =
               ClaudeManagedAgents.reconnect_with_events(conn, self(), MapSet.new())

      assert_receive {:connected,
                      %{tenant: "t1", step_id: "step-2", session_id: "correlated-session"}},
                     1000

      conn
    end)
  end
end
