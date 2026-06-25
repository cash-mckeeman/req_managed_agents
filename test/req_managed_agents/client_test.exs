defmodule ReqManagedAgents.ClientTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Client

  setup do
    # Inject a Req.Test stub via req_options so no real network is used.
    client =
      Client.new(api_key: "sk-test", req_options: [plug: {Req.Test, ReqManagedAgents.ClientTest}])

    {:ok, client: client}
  end

  test "new/1 resolves config with beta + version defaults" do
    c = Client.new(api_key: "sk-x")
    assert c.api_key == "sk-x"
    assert c.base_url == "https://api.anthropic.com"
    assert c.beta == "managed-agents-2026-04-01"
    assert c.anthropic_version == "2023-06-01"
  end

  test "create_session/2 posts to /v1/sessions and returns the body", %{client: client} do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/sessions"
      assert ["managed-agents-2026-04-01"] = Plug.Conn.get_req_header(conn, "anthropic-beta")
      assert ["sk-test"] = Plug.Conn.get_req_header(conn, "x-api-key")
      Req.Test.json(conn, %{"id" => "sess_1", "status" => "running"})
    end)

    assert {:ok, %{"id" => "sess_1"}} =
             Client.create_session(client, %{agent: "agent_1", events: []})
  end

  test "send_events/3 posts the events envelope", %{client: client} do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      assert conn.request_path == "/v1/sessions/sess_1/events"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"events" => [%{"type" => "user.message"}]} = Jason.decode!(body)
      Req.Test.json(conn, %{"ok" => true})
    end)

    ev = ReqManagedAgents.Event.user_message("hi")
    assert {:ok, %{"ok" => true}} = Client.send_events(client, "sess_1", [ev])
  end

  test "list_events/3 GETs with params", %{client: client} do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/sessions/sess_1/events"
      assert conn.query_string == "limit=100"
      Req.Test.json(conn, %{"data" => []})
    end)

    assert {:ok, %{"data" => []}} = Client.list_events(client, "sess_1", %{limit: 100})
  end

  test "non-2xx returns a typed http_error", %{client: client} do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad"})
    end)

    assert {:error, {:http_error, 400, %{"error" => "bad"}}} =
             Client.get_session(client, "sess_x")
  end
end
