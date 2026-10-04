defmodule ReqManagedAgents.SessionRequiresActionRecoveryLiveShapeTest do
  @moduledoc """
  Issue #61 reproduced against the real `ClaudeManagedAgents` provider over a
  live-shaped (Bypass) event stream: an agent turn makes two client-side tool calls,
  both get resumed in one POST, but a stale/premature `session.status_idle` re-notifies
  on one of them as still-outstanding BEFORE its own answer has "landed" from the
  Session's point of view. The fix must recover and resume — never POST an empty
  events list.

  Not `async: true` — matches this repo's other `Bypass`-based Session integration
  tests (`session_test.exs`).
  """
  use ExUnit.Case
  alias ReqManagedAgents.{Client, Session, SessionResult}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents
  import ReqManagedAgents.SSEFixtures

  setup do
    bypass = Bypass.open()
    client = Client.new(api_key: "sk-test", base_url: "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass, client: client}
  end

  test "recovers when a stale idle re-references an already-in-flight tool use", %{
    bypass: bypass,
    client: client
  } do
    parent = self()

    Bypass.expect_once(bypass, "POST", "/v1/sessions", fn conn ->
      Req.Test.json(conn, %{"id" => "s61", "status" => "running"})
    end)

    Bypass.expect_once(bypass, "GET", "/v1/sessions/s61/events/stream", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          wire([
            custom_tool_use("u1", "lookup", %{"q" => 1}),
            custom_tool_use("u2", "lookup", %{"q" => 2}),
            requires_action(["u1", "u2"])
          ])
        )

      # give the Session time to run both tools and POST the first (2-result) resume
      Process.sleep(200)

      # The stale/premature idle (real defect shape): its OWN batch carries no
      # agent.custom_tool_use — only u1's echo has "landed" server-side by now, u2's
      # is still outstanding from the CLIENT's own accumulated-history point of view.
      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          wire([
            %{"type" => "user.custom_tool_result", "custom_tool_use_id" => "u1"},
            requires_action(["u2"])
          ])
        )

      Process.sleep(200)
      {:ok, conn} = Plug.Conn.chunk(conn, wire([end_turn()]))
      conn
    end)

    Bypass.expect(bypass, "POST", "/v1/sessions/s61/events", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:posted, Jason.decode!(body)})
      Req.Test.json(conn, %{"ok" => true})
    end)

    handler = fn name, input, _ctx ->
      send(parent, {:tool_called, name, input})
      {:ok, "echo:#{name}"}
    end

    {:ok, _pid} =
      Session.start_link(ClaudeManagedAgents,
        client: client,
        agent_id: "agent_1",
        environment_id: "env_1",
        prompt: "go",
        handler: handler,
        notify: parent
      )

    assert_receive {:tool_called, "lookup", %{"q" => 1}}, 3000
    assert_receive {:tool_called, "lookup", %{"q" => 2}}, 3000

    # the first resume posts BOTH results together
    assert_receive {:posted,
                    %{
                      "events" => [
                        %{"custom_tool_use_id" => "u1"},
                        %{"custom_tool_use_id" => "u2"}
                      ]
                    }},
                   3000

    # NEVER an empty events POST — and u2 gets re-run + re-posted on recovery
    assert_receive {:tool_called, "lookup", %{"q" => 2}}, 3000
    assert_receive {:posted, %{"events" => [%{"custom_tool_use_id" => "u2"}]}}, 3000

    assert_receive {:managed_agents_session, %SessionResult{terminal: :end_turn}},
                   3000
  end
end
