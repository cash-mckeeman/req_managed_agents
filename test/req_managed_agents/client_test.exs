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

  test "new/1 defaults profile to :anthropic" do
    c = Client.new(api_key: "sk-x")
    assert c.profile == :anthropic
  end

  test "new/1 accepts profile: :jido" do
    c = Client.new(api_key: "sk-x", profile: :jido)
    assert c.profile == :jido
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
             Client.create_session(client, %{agent: "agent_1"})
  end

  test "create_environment/2 posts to /v1/environments", %{client: client} do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/environments"
      Req.Test.json(conn, %{"id" => "env_1"})
    end)

    assert {:ok, %{"id" => "env_1"}} =
             Client.create_environment(client, %{
               name: "t",
               config: %{type: "cloud", networking: %{type: "unrestricted"}}
             })
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

  test "archive_agent/2 posts to /v1/agents/{id}/archive", %{client: client} do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/agents/ag_1/archive"
      Req.Test.json(conn, %{"id" => "ag_1", "archived" => true})
    end)

    assert {:ok, %{"archived" => true}} = ReqManagedAgents.Client.archive_agent(client, "ag_1")
  end

  test "archive_environment/2 and archive_session/2 hit their archive paths", %{client: client} do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      assert conn.request_path in ["/v1/environments/env_1/archive", "/v1/sessions/s_1/archive"]
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert {:ok, _} = ReqManagedAgents.Client.archive_environment(client, "env_1")
    assert {:ok, _} = ReqManagedAgents.Client.archive_session(client, "s_1")
  end

  test "list_environments/2 GETs /v1/environments", %{client: client} do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/environments"
      Req.Test.json(conn, %{"data" => []})
    end)

    assert {:ok, %{"data" => []}} = ReqManagedAgents.Client.list_environments(client)
  end

  test "list_all_events/3 pages through the next_page cursor" do
    bypass = Bypass.open()

    client =
      ReqManagedAgents.Client.new(api_key: "sk", base_url: "http://localhost:#{bypass.port}")

    Bypass.expect(bypass, "GET", "/v1/sessions/s1/events", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["limit"] == "100"

      case conn.query_params["page"] do
        nil ->
          Req.Test.json(conn, %{
            "data" => [%{"id" => "e1"}, %{"id" => "e2"}],
            "next_page" => "cur2"
          })

        "cur2" ->
          Req.Test.json(conn, %{"data" => [%{"id" => "e3"}]})
      end
    end)

    assert {:ok, events} = ReqManagedAgents.Client.list_all_events(client, "s1")
    assert Enum.map(events, & &1["id"]) == ["e1", "e2", "e3"]
  end

  test "list_all_events/3 stops when a next_page cursor repeats (no infinite loop)" do
    bypass = Bypass.open()

    client =
      ReqManagedAgents.Client.new(api_key: "sk", base_url: "http://localhost:#{bypass.port}")

    # pathological server: always returns the same next_page cursor
    Bypass.expect(bypass, "GET", "/v1/sessions/s1/events", fn conn ->
      Req.Test.json(conn, %{"data" => [%{"id" => "e1"}], "next_page" => "same"})
    end)

    # the cursor-repeat guard stops it after fetching the repeated cursor once,
    # so it terminates (bounded) rather than looping forever
    assert {:ok, events} = ReqManagedAgents.Client.list_all_events(client, "s1")
    assert length(events) == 2
  end

  test "upload_file/2 posts multipart to /v1/files with the files beta + part content-type",
       %{client: client} do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/files"
      assert ["files-api-2025-04-14"] = Plug.Conn.get_req_header(conn, "anthropic-beta")
      [ct] = Plug.Conn.get_req_header(conn, "content-type")
      assert ct =~ "multipart/form-data"
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      # the file PART must declare its own content-type (the API requires mime_type)
      assert raw =~ "text/plain"
      Req.Test.json(conn, %{"id" => "file_1"})
    end)

    assert {:ok, %{"id" => "file_1"}} =
             ReqManagedAgents.Client.upload_file(client, %{
               purpose: "agent",
               file: {"d.txt", "hello"}
             })
  end

  test "download_file/2 sends combined beta and returns raw bytes", %{client: client} do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      assert conn.request_path == "/v1/files/file_1/content"

      assert ["files-api-2025-04-14,managed-agents-2026-04-01"] =
               Plug.Conn.get_req_header(conn, "anthropic-beta")

      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream")
      |> Plug.Conn.resp(200, "RAWBYTES")
    end)

    assert {:ok, "RAWBYTES"} = ReqManagedAgents.Client.download_file(client, "file_1")
  end

  test "attach_file_to_session/3 posts a file resource", %{client: client} do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      assert conn.request_path == "/v1/sessions/s1/resources"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{"type" => "file", "file_id" => "file_1", "mount_path" => "/data/d.txt"} =
               Jason.decode!(body)

      Req.Test.json(conn, %{"id" => "res_1"})
    end)

    assert {:ok, %{"id" => "res_1"}} =
             ReqManagedAgents.Client.attach_file_to_session(client, "s1", %{
               file_id: "file_1",
               mount_path: "/data/d.txt"
             })
  end

  test "list_files sends GET /v1/files with scope_id param and BOTH beta headers", %{
    client: client
  } do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/files"
      assert conn.query_string =~ "scope_id=sess_1"

      assert {"anthropic-beta", beta} =
               Enum.find(conn.req_headers, fn {k, _} -> k == "anthropic-beta" end)

      assert beta =~ "files-api-2025-04-14"
      assert beta =~ "managed-agents-2026-04-01"

      Req.Test.json(conn, %{
        "data" => [%{"id" => "file_1", "filename" => "report.md", "size_bytes" => 12}]
      })
    end)

    assert {:ok, %{"data" => [%{"id" => "file_1"}]}} =
             ReqManagedAgents.Client.list_files(client, params: %{scope_id: "sess_1"})
  end

  test "list_files without params sends no query string", %{client: client} do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/files"
      assert conn.query_string == ""
      Req.Test.json(conn, %{"data" => []})
    end)

    assert {:ok, %{"data" => []}} = ReqManagedAgents.Client.list_files(client)
  end

  test "delete_file sends DELETE /v1/files/{id} with both beta headers", %{client: client} do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/v1/files/file_9"

      assert {"anthropic-beta", beta} =
               Enum.find(conn.req_headers, fn {k, _} -> k == "anthropic-beta" end)

      assert beta =~ "files-api-2025-04-14"
      assert beta =~ "managed-agents-2026-04-01"
      Req.Test.json(conn, %{"id" => "file_9", "deleted" => true})
    end)

    assert {:ok, %{"deleted" => true}} = ReqManagedAgents.Client.delete_file(client, "file_9")
  end
end
