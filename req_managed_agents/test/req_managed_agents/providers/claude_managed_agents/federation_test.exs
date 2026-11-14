defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.FederationTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias ReqManagedAgents.Providers.ClaudeManagedAgents.{Auth, Client, Federation}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Federation.Cache
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Federation.Cache.Entry

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

    %Entry{credential: credential} =
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
    assert %Entry{} = Cache.fetch(key)

    # Not yet expired: kept.
    assert {:ok, _} = Federation.token(other, http(), 2_000)
    assert %Entry{} = Cache.fetch(key)

    third = fed(ctx.rule <> "-third", ctx.path)
    assert {:ok, _} = Federation.token(third, http(), 1_000 + 3_600 + 1)
    assert Cache.fetch(key) == nil
  end

  describe "credential safety" do
    test "an exchange is neither retried nor redirected", ctx do
      attempts = counter()

      Req.Test.stub(__MODULE__, fn conn ->
        :counters.add(attempts, 1, 1)
        Plug.Conn.send_resp(conn, 503, "unavailable")
      end)

      retrying = [
        plug: {Req.Test, __MODULE__},
        retry: :transient,
        retry_delay: 0,
        max_retries: 3,
        retry_log_level: false
      ]

      assert {:error, :exchange_failed} =
               Federation.token(fed(ctx.rule, ctx.path), http(req_options: retrying), 1_000)

      assert count(attempts) == 1
    end

    test "an exchange does not follow a redirect", ctx do
      attempts = counter()

      Req.Test.stub(__MODULE__, fn conn ->
        :counters.add(attempts, 1, 1)

        conn
        |> Plug.Conn.put_resp_header("location", "https://other.example/steal")
        |> Plug.Conn.send_resp(307, "")
      end)

      assert {:error, :exchange_failed} =
               Federation.token(fed(ctx.rule, ctx.path), http(), 1_000)

      assert count(attempts) == 1
    end

    test "a federated API call does not follow a redirect with the token", ctx do
      attempts = counter()
      parent = self()

      Req.Test.stub(__MODULE__, fn
        %{request_path: "/v1/oauth/token"} = conn ->
          Req.Test.json(conn, %{access_token: "sk-ant-oat01-redirect", expires_in: 3600})

        conn ->
          :counters.add(attempts, 1, 1)
          send(parent, {:api_host, conn.host})

          conn
          |> Plug.Conn.put_resp_header("location", "https://other.example/steal")
          |> Plug.Conn.send_resp(307, "")
      end)

      assert {:error, {:http_error, 307, _}} = Client.get_session(client(ctx.rule, ctx.path), "s")
      assert count(attempts) == 1
      refute_received {:api_host, "other.example"}
    end

    test "a token scoped to one workspace is not served for another", ctx do
      stub_endpoint(ctx.exchanges)
      a = fed(ctx.rule, ctx.path, workspace_id: "wrkspc_a")
      b = fed(ctx.rule, ctx.path, workspace_id: "wrkspc_b")

      assert {:ok, "sk-ant-oat01-token-1"} = Federation.token(a, http(), 1_000)
      assert {:ok, "sk-ant-oat01-token-2"} = Federation.token(b, http(), 1_000)
      assert {:ok, "sk-ant-oat01-token-1"} = Federation.token(a, http(), 1_001)

      assert_received {:exchange, %{"workspace_id" => "wrkspc_a"}, _}
      assert_received {:exchange, %{"workspace_id" => "wrkspc_b"}, _}
      assert count(ctx.exchanges) == 2
    end

    test "refresh starts 120 seconds before expiry, not before", ctx do
      stub_endpoint(ctx.exchanges)
      f = fed(ctx.rule, ctx.path)
      expiry = 1_000 + 3_600

      assert {:ok, "sk-ant-oat01-token-1"} = Federation.token(f, http(), 1_000)
      assert {:ok, "sk-ant-oat01-token-1"} = Federation.token(f, http(), expiry - 121)
      assert count(ctx.exchanges) == 1
      assert {:ok, "sk-ant-oat01-token-2"} = Federation.token(f, http(), expiry - 119)
    end

    test "an identity token over 16 KiB is refused without an exchange", ctx do
      Req.Test.stub(__MODULE__, fn _ -> flunk("exchanged an oversized identity token") end)
      f = fed(ctx.rule, ctx.path)

      File.write!(ctx.path, String.duplicate("a", 16_385))
      assert {:error, :identity_token_invalid} = Federation.token(f, http(), 1_000)

      oversized =
        fed(ctx.rule <> "-fn", nil,
          identity_token_file: nil,
          identity_token: fn ->
            {:ok, String.duplicate("a", 16_385)}
          end
        )

      assert {:error, :identity_token_invalid} = Federation.token(oversized, http(), 1_000)
    end

    test "an identity token of exactly 16 KiB is accepted", ctx do
      stub_endpoint(ctx.exchanges)
      File.write!(ctx.path, String.duplicate("a", 16_384))
      assert {:ok, _} = Federation.token(fed(ctx.rule, ctx.path), http(), 1_000)
    end

    test "429 is a transient failure, not a rejection, and is paused like one", ctx do
      attempts = counter()

      Req.Test.stub(__MODULE__, fn conn ->
        :counters.add(attempts, 1, 1)
        Plug.Conn.send_resp(conn, 429, "slow down")
      end)

      f = fed(ctx.rule, ctx.path)
      assert {:error, :exchange_failed} = Federation.token(f, http(), 1_000)
      assert {:error, :exchange_failed} = Federation.token(f, http(), 1_001)
      assert count(attempts) == 1
    end
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

  describe "bounded waits" do
    # An identity-token function that reports itself, then waits to be released.
    defp gated_function do
      parent = self()

      fn ->
        send(parent, {:in_function, self()})

        receive do
          :go -> {:ok, "gated-jwt"}
        end
      end
    end

    defp release do
      assert_receive {:in_function, pid}, 2_000
      send(pid, :go)
    end

    test "a slow function does not delay a caller holding a usable token", ctx do
      stub_endpoint(ctx.exchanges)
      f = fed(ctx.rule, nil, identity_token: gated_function(), identity_token_file: nil)

      first = Task.async(fn -> Federation.token(f, http(), 1_000) end)
      release()
      assert {:ok, "sk-ant-oat01-token-1"} = Task.await(first)

      # Inside the advisory window one caller refreshes and stalls in the function.
      window = 1_000 + 3_600 - 100
      refresher = Task.async(fn -> Federation.token(f, http(), window) end)
      assert_receive {:in_function, stalled}, 2_000

      {micros, result} = :timer.tc(fn -> Federation.token(f, http(), window) end)
      assert result == {:ok, "sk-ant-oat01-token-1"}
      assert micros < 200_000

      send(stalled, :go)
      assert {:ok, "sk-ant-oat01-token-2"} = Task.await(refresher)
    end

    test "a hung identity token function times out without an exchange", ctx do
      Req.Test.stub(__MODULE__, fn _ -> flunk("exchanged without an identity token") end)

      f =
        fed(ctx.rule, nil,
          identity_token: fn -> Process.sleep(:infinity) end,
          identity_token_file: nil,
          identity_token_timeout: 50
        )

      assert {:error, :identity_token_timeout} = Federation.token(f, http(), 1_000)
    end

    test "a caller with no usable token waits at most the exchange timeout", ctx do
      stub_endpoint(ctx.exchanges)
      gated = gated_function()
      holder = fed(ctx.rule, nil, identity_token: gated, identity_token_file: nil)
      waiter = %{holder | exchange_timeout: 100}

      first = Task.async(fn -> Federation.token(holder, http(), 1_000) end)
      assert_receive {:in_function, stalled}, 2_000

      {micros, result} = :timer.tc(fn -> Federation.token(waiter, http(), 1_000) end)
      assert result == {:error, :exchange_timeout}
      assert micros < 1_000_000

      send(stalled, :go)
      assert {:ok, _} = Task.await(first)
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

    test "a failure with no cached token is shared, spending one exchange", ctx do
      attempts = counter()
      calls = counter()

      Req.Test.stub(__MODULE__, fn conn ->
        :counters.add(attempts, 1, 1)
        Plug.Conn.send_resp(conn, 503, "secret-body")
      end)

      fun = fn ->
        :counters.add(calls, 1, 1)
        {:ok, "jwt-#{count(calls)}"}
      end

      f = fed(ctx.rule, nil, identity_token: fun, identity_token_file: nil)

      for _ <- 1..3 do
        assert {:error, :exchange_failed} = Federation.token(f, http(), 1_000)
      end

      tasks = for _ <- 1..5, do: Task.async(fn -> Federation.token(f, http(), 1_001) end)
      assert Enum.all?(Task.await_many(tasks), &(&1 == {:error, :exchange_failed}))

      assert count(attempts) == 1
      assert count(calls) == 1

      # After the pause the next caller exchanges again.
      assert {:error, _} = Federation.token(f, http(), 1_011)
      assert count(attempts) == 2
    end

    test "a rejected exchange is shared the same way", ctx do
      attempts = counter()

      Req.Test.stub(__MODULE__, fn conn ->
        :counters.add(attempts, 1, 1)
        Plug.Conn.send_resp(conn, 401, "{}")
      end)

      f = fed(ctx.rule, ctx.path)
      for _ <- 1..3, do: assert({:error, :exchange_rejected} = Federation.token(f, http(), 1_000))
      assert count(attempts) == 1
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
