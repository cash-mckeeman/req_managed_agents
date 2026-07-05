defmodule ReqManagedAgents.SessionOutcomeTest do
  use ExUnit.Case
  alias ReqManagedAgents.{Client, Session}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents
  import ReqManagedAgents.SSEFixtures

  setup do
    bypass = Bypass.open()
    client = Client.new(api_key: "sk", base_url: "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass, client: client}
  end

  test "outcome kickoff → needs_revision is not terminal → satisfied finishes", %{
    bypass: bypass,
    client: client
  } do
    test = self()

    Bypass.expect_once(bypass, "POST", "/v1/sessions", fn conn ->
      Req.Test.json(conn, %{"id" => "s1"})
    end)

    Bypass.expect_once(bypass, "GET", "/v1/sessions/s1/events/stream", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          wire([
            %{"type" => "span.outcome_evaluation_end", "verdict" => "needs_revision"},
            %{"type" => "agent.message", "content" => [%{"type" => "text", "text" => "v2"}]},
            %{"type" => "session.status_idle", "stop_reason" => %{"type" => "satisfied"}}
          ])
        )

      conn
    end)

    Bypass.expect(bypass, "POST", "/v1/sessions/s1/events", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posted_events, Jason.decode!(body)})
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert {:ok, result} =
             Session.run(ClaudeManagedAgents,
               client: client,
               handler: fn _n, _i, _c -> {:ok, ""} end,
               agent_id: "ag",
               environment_id: "env",
               outcome: %{description: "do the thing", rubric: "- done", max_iterations: 2},
               timeout: 5_000
             )

    # Terminal only at status_idle satisfied — one turn, not two.
    assert result.terminal == :end_turn
    assert result.stop_reason == %{"type" => "satisfied"}
    assert result.turns == 1

    # The kickoff POST carried the define_outcome event, not a user.message.
    # (Client.send_events/3 posts %{events: events} — see lib/req_managed_agents/client.ex:141.)
    assert_received {:posted_events, %{"events" => kicked}}

    assert Enum.any?(kicked, fn e ->
             e["type"] == "user.define_outcome" and e["max_iterations"] == 2
           end)
  end

  test "outcome on a non-supporting provider is rejected at start" do
    assert {:error, :outcome_unsupported} =
             Session.run(ReqManagedAgents.FakeProviders.RequestResponse,
               handler: fn _, _, _ -> {:ok, ""} end,
               turns: [],
               outcome: %{description: "d", rubric: "r"}
             )
  end

  test "outcome as a plain string is rejected at start with invalid_opts" do
    assert {:error, {:invalid_opts, :outcome}} =
             Session.run(ClaudeManagedAgents,
               handler: fn _, _, _ -> {:ok, ""} end,
               outcome: "do it"
             )
  end

  test "outcome with string keys is rejected at start with invalid_opts" do
    assert {:error, {:invalid_opts, :outcome}} =
             Session.run(ClaudeManagedAgents,
               handler: fn _, _, _ -> {:ok, ""} end,
               outcome: %{"description" => "d", "rubric" => "r"}
             )
  end
end
