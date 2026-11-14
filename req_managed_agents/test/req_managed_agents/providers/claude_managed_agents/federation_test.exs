defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.FederationTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias ReqManagedAgents.Providers.ClaudeManagedAgents.{Auth, Client, Federation}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Federation.Cache

  @env ~w(ANTHROPIC_API_KEY ANTHROPIC_BEARER_TOKEN_FILE ANTHROPIC_FEDERATION_RULE_ID
          ANTHROPIC_ORGANIZATION_ID ANTHROPIC_SERVICE_ACCOUNT_ID ANTHROPIC_WORKSPACE_ID
          ANTHROPIC_IDENTITY_TOKEN_FILE)

  setup do
    saved = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)

    on_exit(fn ->
      for {name, value} <- saved do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    dir = Path.join(System.tmp_dir!(), "fed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "identity.jwt")
    File.write!(path, "jwt-1\n")

    # The cache is shared across tests, so each test federates under its own rule.
    %{path: path, rule: "fdrl_#{System.unique_integer([:positive])}", exchanges: counter()}
  end

  defp counter, do: :counters.new(1, [])
  defp count(c), do: :counters.get(c, 1)

  defp client(rule, path, opts \\ []) do
    Client.new(
      Keyword.merge(
        [
          api_key: nil,
          federation_rule_id: rule,
          organization_id: "org-uuid",
          workspace_id: "wrkspc_1",
          identity_token_file: path,
          req_options: [plug: {Req.Test, __MODULE__}, retry_delay: 0, retry_log_level: false]
        ],
        opts
      )
    )
  end

  # Answers every exchange with a numbered access token and records each request body.
  defp stub_endpoint(exchanges, opts \\ []) do
    parent = self()
    expires_in = Keyword.get(opts, :expires_in, 3600)

    Req.Test.stub(__MODULE__, fn
      %{request_path: "/v1/oauth/token"} = conn ->
        :counters.add(exchanges, 1, 1)
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(
          parent,
          {:exchange, Jason.decode!(body), Plug.Conn.get_req_header(conn, "content-type")}
        )

        Req.Test.json(conn, %{
          access_token: "sk-ant-oat01-token-#{count(exchanges)}",
          token_type: "Bearer",
          expires_in: expires_in
        })

      conn ->
        send(parent, {:api, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{"id" => "s"})
    end)
  end

  defp fed(rule, path, extra \\ []) do
    struct!(
      Federation,
      Keyword.merge(
        [rule_id: rule, organization_id: "org-uuid", identity_token_file: path],
        extra
      )
    )
  end

  defp http(opts \\ []) do
    %{
      base_url: "https://api.anthropic.com",
      receive_timeout: 5_000,
      req_options: [plug: {Req.Test, __MODULE__}]
    }
    |> Map.merge(Map.new(opts))
  end

  test "a file source exchanges once, sends the documented request, and caches", ctx do
    stub_endpoint(ctx.exchanges)
    c = client(ctx.rule, ctx.path)

    assert {:ok, _} = Client.get_session(c, "s")
    assert {:ok, _} = Client.get_session(c, "s")

    assert_received {:exchange, body, ["application/json" <> _]}

    assert body == %{
             "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
             "assertion" => "jwt-1",
             "federation_rule_id" => ctx.rule,
             "organization_id" => "org-uuid",
             "workspace_id" => "wrkspc_1"
           }

    assert_received {:api, ["Bearer sk-ant-oat01-token-1"]}
    assert_received {:api, ["Bearer sk-ant-oat01-token-1"]}
    assert count(ctx.exchanges) == 1
  end

  test "a refresh rereads the identity token file", ctx do
    stub_endpoint(ctx.exchanges)
    f = fed(ctx.rule, ctx.path)

    assert {:ok, "sk-ant-oat01-token-1"} = Federation.token(f, http(), 1_000)
    File.write!(ctx.path, "jwt-2")
    # 3600 s lifetime: inside the 120 s advisory window.
    assert {:ok, "sk-ant-oat01-token-2"} = Federation.token(f, http(), 1_000 + 3_600 - 100)

    assert_received {:exchange, %{"assertion" => "jwt-1"}, _}
    assert_received {:exchange, %{"assertion" => "jwt-2"}, _}
  end

  test "an identity token function is called exactly once per exchange", ctx do
    stub_endpoint(ctx.exchanges)
    calls = counter()

    fun = fn ->
      :counters.add(calls, 1, 1)
      {:ok, "fn-jwt-#{count(calls)}"}
    end

    f = fed(ctx.rule, nil, identity_token: fun, identity_token_file: nil)

    assert {:ok, _} = Federation.token(f, http(), 1_000)
    assert {:ok, _} = Federation.token(f, http(), 1_500)
    assert count(calls) == 1
    assert {:ok, _} = Federation.token(f, http(), 1_000 + 3_600 - 100)
    assert count(calls) == 2

    assert_received {:exchange, %{"assertion" => "fn-jwt-1"}, _}
    assert_received {:exchange, %{"assertion" => "fn-jwt-2"}, _}
    refute_received {:exchange, _, _}
  end

  test "a Messages retry reuses the cached access token", ctx do
    parent = self()
    attempts = counter()

    Req.Test.stub(__MODULE__, fn
      %{request_path: "/v1/oauth/token"} = conn ->
        :counters.add(ctx.exchanges, 1, 1)
        Req.Test.json(conn, %{access_token: "sk-ant-oat01-once", expires_in: 3600})

      conn ->
        :counters.add(attempts, 1, 1)
        send(parent, {:api, Plug.Conn.get_req_header(conn, "authorization")})

        if count(attempts) == 1,
          do: Plug.Conn.send_resp(conn, 503, "retry"),
          else: Req.Test.json(conn, %{"id" => "s"})
    end)

    c =
      client(ctx.rule, ctx.path,
        req_options: [
          plug: {Req.Test, __MODULE__},
          retry_delay: 0,
          retry_log_level: false,
          max_retries: 1
        ]
      )

    assert {:ok, %{"id" => "s"}} = Client.get_session(c, "s")
    assert_received {:api, ["Bearer sk-ant-oat01-once"]}
    assert_received {:api, ["Bearer sk-ant-oat01-once"]}
    assert count(attempts) == 2
    assert count(ctx.exchanges) == 1
  end

  test "a rejected exchange leaks neither the identity token, the access token nor the body",
       ctx do
    File.write!(ctx.path, "secret-identity-jwt")

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        401,
        Jason.encode!(%{
          access_token: "sk-ant-oat01-leaked",
          error: %{message: "body-marker secret-identity-jwt"}
        })
      )
    end)

    c = client(ctx.rule, ctx.path)

    log =
      capture_log(fn ->
        assert {:error, {:authentication_error, :exchange_rejected}} = Client.get_session(c, "s")
        error = assert_raise Auth.Error, fn -> Client.headers(c) end
        send(self(), {:message, Exception.message(error)})
      end)

    assert_received {:message, message}

    for text <- [log, message, inspect(c)] do
      refute text =~ "secret-identity-jwt"
      refute text =~ "sk-ant-oat01-leaked"
      refute text =~ "body-marker"
    end
  end

  test "an inspected client and credential hide the access token", ctx do
    stub_endpoint(ctx.exchanges)
    f = fed(ctx.rule, ctx.path)
    assert {:ok, _} = Federation.token(f, http(), 1_000)

    {credential, _} =
      Cache.fetch(
        {"https://api.anthropic.com", ctx.rule, "org-uuid", nil, nil, {:file, ctx.path}}
      )

    refute inspect(credential) =~ "sk-ant-oat01-token-1"
  end

  test "clients with fresh closures and the same cache key share one exchange", ctx do
    stub_endpoint(ctx.exchanges)

    clients =
      for n <- 1..2 do
        client(ctx.rule, nil,
          identity_token_file: nil,
          identity_token: fn -> {:ok, "closure-#{n}"} end,
          cache_key: {:shared, ctx.rule}
        )
      end

    for c <- clients, do: assert({:ok, _} = Client.get_session(c, "s"))
    assert count(ctx.exchanges) == 1

    # Without a cache key each closure is its own credential.
    for n <- 1..2 do
      c =
        client(ctx.rule, nil,
          identity_token_file: nil,
          identity_token: fn -> {:ok, "closure-#{n}"} end
        )

      assert {:ok, _} = Client.get_session(c, "s")
    end

    assert count(ctx.exchanges) == 3
  end

  test "expired entries are dropped when a later entry is written", ctx do
    stub_endpoint(ctx.exchanges)
    first = fed(ctx.rule, ctx.path)
    other = fed(ctx.rule <> "-later", ctx.path)

    assert {:ok, _} = Federation.token(first, http(), 1_000)
    key = {"https://api.anthropic.com", ctx.rule, "org-uuid", nil, nil, {:file, ctx.path}}
    assert {_, _} = Cache.fetch(key)

    # Not yet expired: kept.
    assert {:ok, _} = Federation.token(other, http(), 2_000)
    assert {_, _} = Cache.fetch(key)

    third = fed(ctx.rule <> "-third", ctx.path)
    assert {:ok, _} = Federation.token(third, http(), 1_000 + 3_600 + 1)
    assert Cache.fetch(key) == nil
  end

  describe "credential selection" do
    test "an API key alongside federation settings is refused, naming both", ctx do
      error =
        assert_raise ArgumentError, fn ->
          Client.new(
            api_key: "secret-static-key",
            federation_rule_id: ctx.rule,
            organization_id: "org-uuid",
            identity_token_file: ctx.path
          )
        end

      assert error.message =~ "api_key"
      assert error.message =~ "federation"
      refute error.message =~ "secret-static-key"
    end

    test "the conflict message says what switched federation on and how to resolve it", ctx do
      error =
        assert_raise ArgumentError, fn ->
          Client.new(
            api_key: "secret-static-key",
            federation_rule_id: ctx.rule,
            organization_id: "org-uuid",
            identity_token_file: ctx.path
          )
        end

      for fragment <- [
            "ANTHROPIC_FEDERATION_RULE_ID",
            "`api_key: nil`",
            "`federation_rule_id: nil`",
            "unset ANTHROPIC_FEDERATION_RULE_ID"
          ] do
        assert error.message =~ fragment
      end

      refute error.message =~ "secret-static-key"
      refute error.message =~ ctx.rule

      # Both escape hatches work.
      opts = [
        federation_rule_id: ctx.rule,
        organization_id: "org-uuid",
        identity_token_file: ctx.path
      ]

      assert %Client{api_key: "k", federation: nil} =
               Client.new(
                 [api_key: "k", federation_rule_id: nil] ++
                   Keyword.delete(opts, :federation_rule_id)
               )

      assert %Client{api_key: nil, federation: %Federation{}} = Client.new([api_key: nil] ++ opts)
    end

    test "an existing API key client fails on a stray federation rule variable", ctx do
      System.put_env("ANTHROPIC_FEDERATION_RULE_ID", ctx.rule)

      error = assert_raise ArgumentError, fn -> Client.new(api_key: "k") end
      assert error.message =~ "api_key"
      assert error.message =~ "ANTHROPIC_FEDERATION_RULE_ID"

      # Unsetting the variable restores the API key; so does disabling the rule.
      assert %Client{api_key: "k", federation: nil} =
               Client.new(api_key: "k", federation_rule_id: nil)

      System.delete_env("ANTHROPIC_FEDERATION_RULE_ID")
      assert %Client{api_key: "k", federation: nil} = Client.new(api_key: "k")
    end

    test "the same conflict is found through the official environment variables", ctx do
      System.put_env("ANTHROPIC_API_KEY", "secret-env-key")
      System.put_env("ANTHROPIC_FEDERATION_RULE_ID", ctx.rule)
      System.put_env("ANTHROPIC_ORGANIZATION_ID", "org-uuid")
      System.put_env("ANTHROPIC_IDENTITY_TOKEN_FILE", ctx.path)

      error = assert_raise ArgumentError, fn -> Client.new([]) end
      assert error.message =~ "api_key"
      assert error.message =~ "federation"

      # Explicit nil disables the key, as for the other sources.
      assert %Client{federation: %Federation{rule_id: rule}} = Client.new(api_key: nil)
      assert rule == ctx.rule
    end

    test "federation is configured from the official environment variables", ctx do
      System.put_env("ANTHROPIC_FEDERATION_RULE_ID", ctx.rule)
      System.put_env("ANTHROPIC_ORGANIZATION_ID", "org-uuid")
      System.put_env("ANTHROPIC_SERVICE_ACCOUNT_ID", "svac_1")
      System.put_env("ANTHROPIC_WORKSPACE_ID", "wrkspc_9")
      System.put_env("ANTHROPIC_IDENTITY_TOKEN_FILE", ctx.path)

      assert %Client{api_key: nil, federation: federation} = Client.new([])

      assert %Federation{
               rule_id: rule,
               organization_id: "org-uuid",
               service_account_id: "svac_1",
               workspace_id: "wrkspc_9",
               identity_token_file: path
             } = federation

      assert {rule, path} == {ctx.rule, ctx.path}
    end

    test "a function alone supplies the identity token", ctx do
      fun = fn -> {:ok, "jwt"} end

      assert %Client{federation: %Federation{identity_token: ^fun}} =
               Client.new(
                 federation_rule_id: ctx.rule,
                 organization_id: "org-uuid",
                 identity_token: fun
               )
    end

    test "incomplete federation names what is missing", ctx do
      error = assert_raise ArgumentError, fn -> Client.new(federation_rule_id: ctx.rule) end
      assert error.message =~ "organization_id"
      assert error.message =~ "identity_token_file"
    end

    test "federation is refused alongside a bearer file", ctx do
      error =
        assert_raise ArgumentError, fn ->
          Client.new(
            bearer_token_file: ctx.path,
            federation_rule_id: ctx.rule,
            organization_id: "org-uuid",
            identity_token_file: ctx.path
          )
        end

      assert error.message =~ "bearer_token_file"
    end
  end

  describe "refresh timing" do
    test "an expired cache re-exchanges before the request", ctx do
      stub_endpoint(ctx.exchanges)
      f = fed(ctx.rule, ctx.path)

      assert {:ok, "sk-ant-oat01-token-1"} = Federation.token(f, http(), 1_000)
      # Inside the mandatory 30 s margin the cached token is not usable.
      File.write!(ctx.path, "jwt-2")
      assert {:ok, "sk-ant-oat01-token-2"} = Federation.token(f, http(), 1_000 + 3_600 - 10)
      assert {:ok, "sk-ant-oat01-token-2"} = Federation.token(f, http(), 1_000 + 3_600)
      assert count(ctx.exchanges) == 2
    end

    test "a failed exchange inside the advisory window serves the cached token, then fails",
         ctx do
      stub_endpoint(ctx.exchanges)
      f = fed(ctx.rule, ctx.path)
      assert {:ok, "sk-ant-oat01-token-1"} = Federation.token(f, http(), 1_000)

      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

      window = 1_000 + 3_600 - 100
      assert {:ok, "sk-ant-oat01-token-1"} = Federation.token(f, http(), window)
      # Retries pause briefly instead of spending an identity token per request.
      Req.Test.stub(__MODULE__, fn _ -> flunk("exchange retried during backoff") end)
      assert {:ok, "sk-ant-oat01-token-1"} = Federation.token(f, http(), window + 5)

      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)
      assert {:ok, "sk-ant-oat01-token-1"} = Federation.token(f, http(), window + 15)

      assert {:error, :exchange_failed} = Federation.token(f, http(), 1_000 + 3_600 - 20)
    end

    test "an unreadable identity token file fails without calling the endpoint", ctx do
      Req.Test.stub(__MODULE__, fn _ -> flunk("exchanged without an identity token") end)
      f = fed(ctx.rule, ctx.path <> ".missing")
      assert {:error, :identity_token_unreadable} = Federation.token(f, http(), 1_000)
    end

    test "an identity token function that fails or raises is reported without its reason", ctx do
      Req.Test.stub(__MODULE__, fn _ -> flunk("exchanged without an identity token") end)

      for fun <- [fn -> {:error, "secret-detail"} end, fn -> raise "secret-detail" end] do
        f = fed(ctx.rule, nil, identity_token: fun, identity_token_file: nil)
        assert {:error, :identity_token_unavailable} = Federation.token(f, http(), 1_000)
      end
    end

    test "concurrent callers share one exchange", ctx do
      stub_endpoint(ctx.exchanges)
      f = fed(ctx.rule, ctx.path)
      tasks = for _ <- 1..5, do: Task.async(fn -> Federation.token(f, http(), 1_000) end)
      assert Enum.all?(Task.await_many(tasks), &(&1 == {:ok, "sk-ant-oat01-token-1"}))
      assert count(ctx.exchanges) == 1
    end
  end
end
