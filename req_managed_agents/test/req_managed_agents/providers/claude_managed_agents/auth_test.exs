defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.AuthTest do
  use ExUnit.Case
  alias ReqManagedAgents.Providers.ClaudeManagedAgents, as: Provider
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.{Client, Stream}

  setup do
    for {key, variable} <- [
          api_key: "ANTHROPIC_API_KEY",
          bearer_token_file: "ANTHROPIC_BEARER_TOKEN_FILE"
        ] do
      env = System.fetch_env(variable)
      app = Application.fetch_env(:req_managed_agents, key)
      System.delete_env(variable)
      Application.delete_env(:req_managed_agents, key)

      on_exit(fn ->
        case env do
          {:ok, value} -> System.put_env(variable, value)
          :error -> System.delete_env(variable)
        end

        case app do
          {:ok, value} -> Application.put_env(:req_managed_agents, key, value)
          :error -> Application.delete_env(:req_managed_agents, key)
        end
      end)
    end

    dir = Path.join(System.tmp_dir!(), "auth-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "bearer.json")
    rotate(path, "token-a")
    %{path: path}
  end

  defp rotate(path, token, expiry \\ nil) do
    File.write!(
      path <> ".next",
      Jason.encode!(%{
        access_token: token,
        expires_at: expiry || System.system_time(:second) + 600
      })
    )

    File.rename!(path <> ".next", path)
  end

  defp client(path, opts \\ []) do
    Client.new(
      Keyword.merge(
        [
          api_key: nil,
          bearer_token_file: path,
          req_options: [plug: {Req.Test, __MODULE__}, retry_delay: 0, retry_log_level: false]
        ],
        opts
      )
    )
  end

  test "explicit_nil_selects_gateway_key and direct_and_gateway_clients_coexist", %{path: path} do
    System.put_env("ANTHROPIC_BEARER_TOKEN_FILE", path)
    System.put_env("ANTHROPIC_API_KEY", "ambient-key")
    direct = client(path)
    gateway = client(nil, api_key: "grant")

    Req.Test.stub(__MODULE__, fn conn ->
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer token-a"] -> assert Plug.Conn.get_req_header(conn, "x-api-key") == []
        [] -> assert Plug.Conn.get_req_header(conn, "x-api-key") == ["grant"]
      end

      Req.Test.json(conn, %{"id" => "s"})
    end)

    assert {:ok, _} = Client.get_session(direct, "s")
    assert {:ok, _} = Client.get_session(gateway, "s")
  end

  test "resolves option then app then env and rejects ambiguous credentials", %{path: path} do
    System.put_env("ANTHROPIC_BEARER_TOKEN_FILE", "env-path")
    Application.put_env(:req_managed_agents, :bearer_token_file, "app-path")
    assert Client.new(api_key: nil).bearer_token_file == "app-path"
    assert Client.new(api_key: nil, bearer_token_file: path).bearer_token_file == path
    Application.delete_env(:req_managed_agents, :bearer_token_file)
    assert Client.new(api_key: nil).bearer_token_file == "env-path"

    for key <- ["secret-conflict", ""] do
      error =
        assert_raise ArgumentError, fn -> Client.new(api_key: key, bearer_token_file: path) end

      refute Exception.message(error) =~ "secret-conflict"
    end

    assert_raise ArgumentError, fn -> Client.new(api_key: nil, bearer_token_file: nil) end
  end

  test "canonical and compatibility JSON calls reread rotated credentials", %{path: path} do
    for module <- [Client, ReqManagedAgents.Client] do
      rotate(path, "token-a")

      c =
        module.new(
          api_key: nil,
          bearer_token_file: path,
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-api-key") == []
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token-a"]
        Req.Test.json(conn, %{"id" => "s"})
      end)

      assert {:ok, _} = module.create_session(c, %{agent: "a"})
      rotate(path, "token-b")

      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token-b"]
        Req.Test.json(conn, %{"id" => "s"})
      end)

      assert {:ok, _} = module.get_session(c, "s")
      refute inspect(c) =~ "token-b"
    end
  end

  test "Files upload download listing deletion and attachment use current bearer", %{path: path} do
    c = client(path)

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token-a"]
      assert Plug.Conn.get_req_header(conn, "x-api-key") == []
      Req.Test.json(conn, %{"id" => "f", "data" => []})
    end)

    assert {:ok, _} = Client.upload_file(c, %{purpose: "agent", file: {"a.txt", "bytes"}})
    assert {:ok, _} = Client.list_files(c)
    assert {:ok, _} = Client.download_file(c, "f")
    assert {:ok, _} = Client.delete_file(c, "f")

    assert {:ok, _} =
             Client.attach_file_to_session(c, "s", %{file_id: "f", mount_path: "/data/a.txt"})
  end

  test "transient retries reread the file instead of retaining the first token", %{path: path} do
    c =
      client(path,
        req_options: [
          plug: {Req.Test, __MODULE__},
          retry_delay: 0,
          retry_log_level: false,
          max_retries: 1
        ]
      )

    Req.Test.expect(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token-a"]
      rotate(path, "token-b")
      Plug.Conn.send_resp(conn, 503, "retry")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token-b"]
      Req.Test.json(conn, %{"id" => "s"})
    end)

    assert {:ok, %{"id" => "s"}} = Client.get_session(c, "s")
  end

  test "expired and malformed files fail before JSON Files or SSE dispatch", %{path: path} do
    c = client(path)
    rotate(path, "never-send", System.system_time(:second) + 30)
    Req.Test.stub(__MODULE__, fn _ -> flunk("credential was sent") end)
    assert {:error, {:authentication_error, :expired}} = Client.get_session(c, "s")
    assert {:error, {:authentication_error, :expired}} = Client.list_files(c)
    ref = make_ref()
    assert :ok = Stream.stream(c, "s", self(), ref: ref)
    assert_received {:managed_agents, ^ref, {:error, {:authentication_error, :expired}}}
    File.write!(path, "{")
    assert {:error, {:authentication_error, :invalid_file}} = Client.create_session(c, %{})
  end

  test "bearer redirects are not followed and 401 is not replayed", %{path: path} do
    c = client(path)

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://other.example/secret")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, {:http_error, 302, _}} = Client.get_session(c, "s")
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 401, "denied") end)
    assert {:error, {:http_error, 401, _}} = Client.create_session(c, %{})
  end

  test "session_model_config_selects_bearer_file and SSE reconnect reads rotation", %{path: path} do
    bypass = Bypass.open()
    parent = self()

    Bypass.expect(bypass, fn conn ->
      case conn.request_path do
        "/v1/sessions" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token-a"]

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, ~s({"id":"s"}))

        "/v1/sessions/s/events/stream" ->
          send(parent, {:stream_auth, Plug.Conn.get_req_header(conn, "authorization")})

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.resp(200, "data: {\"type\":\"session.status_idle\"}\n\n")
      end
    end)

    opts = [
      agent_id: "a",
      environment_id: "e",
      model_config: %{
        api_key: nil,
        bearer_token_file: path,
        base_url: "http://localhost:#{bypass.port}"
      }
    ]

    assert {:ok, conn} = Provider.open(opts, self())
    assert_receive {:stream_auth, ["Bearer token-a"]}, 2000
    assert_receive {:managed_agents, _, :done}, 2000
    rotate(path, "token-b")
    ref = make_ref()
    task = Task.async(fn -> Stream.stream(conn.client, "s", parent, ref: ref) end)
    assert_receive {:stream_auth, ["Bearer token-b"]}, 2000
    assert :ok = Task.await(task)
  end
end
