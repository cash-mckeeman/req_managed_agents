defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.HistoryRequestAuthTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.{Client, History}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.History.Request

  test "bearer-only history uses native authentication at each dispatched request" do
    root = Path.join(System.tmp_dir!(), "history-bearer-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "token.json")

    File.write!(
      path,
      Jason.encode!(%{
        access_token: "invented-history-token",
        expires_at: System.system_time(:second) + 600
      })
    )

    File.chmod!(path, 0o600)
    owner = self()

    plug = fn conn ->
      send(
        owner,
        {:history_auth, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"),
         Plug.Conn.get_req_header(conn, "x-api-key")}
      )

      data =
        if String.ends_with?(conn.request_path, "/events"),
          do: [%{"id" => "native-event", "type" => "agent.message"}],
          else: []

      Req.Test.json(conn, %{"data" => data, "has_more" => false})
    end

    client =
      Client.new(api_key: nil, bearer_token_file: path, req_options: [plug: plug, retry: false])

    assert {:ok, request} = Request.new(client: client, options: [max_pages: 2])
    assert {:ok, capture} = History.fetch("session", request)
    assert Enum.any?(capture.records, &(&1.native_id == "native-event"))
    assert Enum.all?(capture.sources, &(&1.status == :complete))

    assert_receive {:history_auth, "/v1/sessions/session/events",
                    ["Bearer invented-history-token"], []}

    assert_receive {:history_auth, "/v1/sessions/session/threads",
                    ["Bearer invented-history-token"], []}

    refute_receive {:history_auth, _, _, _}
  end

  test "history configuration validates the credential source without reading its file" do
    client = Client.new(api_key: nil, bearer_token_file: "/nonexistent-acceptance-token-file")
    assert {:ok, _} = Request.new(client: client)

    for invalid <- [
          %{client | api_key: nil, bearer_token_file: nil},
          %{client | api_key: "invented-conflict"},
          %{client | bearer_token_file: ""}
        ] do
      assert {:error, _} = Request.new(client: invalid)
    end

    assert {:ok, _} =
             Request.new(client: %{client | api_key: "invented-key", bearer_token_file: nil})
  end
end
