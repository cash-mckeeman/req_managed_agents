defmodule ReqManagedAgents.InjectedTransportRefusalTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Providers.{ClaudeManagedAgents, Local}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Client
  alias ReqManagedAgents.{Session, SessionResult}

  setup do
    bypass = Bypass.open()
    owner = self()

    for {method, path} <- [{"POST", "/v1/sessions"}, {"GET", "/v1/sessions/existing/events"}] do
      Bypass.stub(bypass, method, path, fn conn ->
        send(
          owner,
          {:cma_request, conn.method, conn.request_path,
           Plug.Conn.get_req_header(conn, "x-api-key")}
        )

        Plug.Conn.resp(conn, 400, "observed")
      end)
    end

    client =
      Client.new(
        api_key: "injected-key",
        base_url: "http://localhost:#{bypass.port}",
        req_options: [retry: false]
      )

    {:ok, client: client}
  end

  defp cma_opts(client, extra) do
    Keyword.merge(
      [
        client: client,
        agent_id: "agent",
        environment_id: "env",
        handler: fn _, _, _ -> {:ok, ""} end,
        timeout: 2000
      ],
      extra
    )
  end

  for field <- [:api_key, :bearer_token_file, :base_url], resume? <- [false, true] do
    test "CMA refuses #{field} with an injected client on #{if resume?, do: "reattach", else: "create"}",
         %{client: client} do
      value =
        case unquote(field) do
          :api_key -> client.api_key
          :base_url -> client.base_url
          :bearer_token_file -> "/not-opened"
        end

      opts = cma_opts(client, model_config: %{unquote(field) => value})
      opts = if unquote(resume?), do: Keyword.put(opts, :session_id, "existing"), else: opts
      assert Session.run(ClaudeManagedAgents, opts) == {:error, :data_plane_unsupported}
      refute_received {:cma_request, _, _, _}
    end
  end

  test "CMA injected client with metadata and nil data-plane fields still creates a session", %{
    client: client
  } do
    config = %{api_key: nil, bearer_token_file: nil, base_url: nil, metadata: %{request_id: "r"}}

    assert {:error, {:create_session_failed, _}} =
             Session.run(ClaudeManagedAgents, cma_opts(client, model_config: config))

    assert_received {:cma_request, "POST", "/v1/sessions", ["injected-key"]}
  end

  test "CMA injected client without data-plane config still reads reattach history", %{
    client: client
  } do
    assert {:error, reason} =
             Session.run(
               ClaudeManagedAgents,
               cma_opts(client,
                 session_id: "existing",
                 model_config: %{metadata: %{request_id: "r"}}
               )
             )

    refute reason == :data_plane_unsupported
    assert_received {:cma_request, "GET", "/v1/sessions/existing/events", ["injected-key"]}
  end

  test "CMA budget validation retains precedence over injected-transport refusal", %{
    client: client
  } do
    assert ClaudeManagedAgents.open(
             cma_opts(client, budget: :invalid, model_config: %{api_key: "key"}),
             self()
           ) == {:error, {:invalid_opts, :budget}}

    refute_received {:cma_request, _, _, _}
  end

  defp chat(owner) do
    fn request ->
      send(owner, {:chat, request.model})

      {:ok,
       %{
         "choices" => [
           %{
             "message" => %{"role" => "assistant", "content" => "done"},
             "finish_reason" => "stop"
           }
         ]
       }}
    end
  end

  for field <- [:api_key, :base_url] do
    test "Local refuses #{field} before invoking an injected chat callback" do
      config = %{unquote(field) => "value", model: "test:model"}

      assert Session.run(Local,
               handler: fn _, _, _ -> {:ok, ""} end,
               chat_fun: chat(self()),
               model_config: config
             ) == {:error, :data_plane_unsupported}

      refute_received {:chat, _}
    end
  end

  test "Local injected chat still receives model with metadata and explicit nil credentials" do
    config = %{
      model: "test:model",
      metadata: %{request_id: "r"},
      api_key: nil,
      base_url: nil,
      bearer_token_file: nil
    }

    assert {:ok, %SessionResult{terminal: :end_turn, text: "done"}} =
             Session.run(Local,
               handler: fn _, _, _ -> {:ok, ""} end,
               chat_fun: chat(self()),
               model_config: config
             )

    assert_received {:chat, "test:model"}
  end

  for field <- [:api_key, :bearer_token_file, :base_url] do
    test "Local spec fallback refuses #{field} before building an injected connection" do
      opts = [
        spec: %{model_config: %{unquote(field) => "value", model: "test:model"}},
        chat_fun: chat(self())
      ]

      assert Local.open(opts, self()) == {:error, :data_plane_unsupported}
      refute_received {:chat, _}
    end
  end

  test "Local top-level model-only config overrides the spec data-plane fallback" do
    assert {:ok, conn} =
             Local.open(
               [
                 spec: %{model_config: %{api_key: "ignored-fallback"}},
                 model_config: %{model: "test:model"},
                 chat_fun: chat(self())
               ],
               self()
             )

    assert {:ok, _, _} = Local.poll_turn(conn, Local.kickoff_input(prompt: "hello"))
    assert_received {:chat, "test:model"}
  end
end
