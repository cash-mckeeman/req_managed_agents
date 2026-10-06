defmodule ReqManagedAgents.Providers.ClaudeManagedAgentsBudgetTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Client
  alias ReqManagedAgents.Providers.ClaudeManagedAgents, as: ManagedAgents
  alias ReqManagedAgents.SSEFixtures

  @wire_budget %{
    "type" => "limit",
    "max_list_cost" => %{"amount" => "125", "currency" => "USD"}
  }

  @archive_delay_ms 150

  setup do
    bypass = Bypass.open()
    test = self()

    # Every request the stub sees is reported to the test process, so "no request" and
    # "no send-event call" are assertions on observed traffic, not on a return value.
    Bypass.stub(bypass, "GET", "/v1/sessions/s1/events/stream", fn conn ->
      send(test, {:request, "GET", conn.request_path})
      Plug.Conn.send_chunked(conn, 200)
    end)

    Bypass.stub(bypass, "POST", "/v1/sessions/s1/events", fn conn ->
      send(test, {:request, "POST", conn.request_path})
      Req.Test.json(conn, %{"ok" => true})
    end)

    # The archive answers slowly, as a network round trip does. A stream started before
    # confirmation would issue its GET inside this window; with an instant archive the
    # failed open tears the stream task down before the GET lands and the refute is blind.
    Bypass.stub(bypass, "POST", "/v1/sessions/s1/archive", fn conn ->
      send(test, {:request, "POST", conn.request_path})
      Process.sleep(@archive_delay_ms)
      Req.Test.json(conn, %{"id" => "s1"})
    end)

    client = Client.new(api_key: "sk-test", base_url: "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass, client: client}
  end

  defp stub_create(bypass, response) do
    test = self()

    Bypass.stub(bypass, "POST", "/v1/sessions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, "POST", conn.request_path})
      send(test, {:create_body, raw})
      Req.Test.json(conn, response)
    end)
  end

  defp open_opts(client, extra),
    do: [client: client, agent_id: "ag", environment_id: "env"] ++ extra

  defp requests(acc \\ []) do
    receive do
      {:request, method, path} -> requests([{method, path} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  test "without a budget the create-session body is exactly agent and environment_id",
       %{bypass: bypass, client: client} do
    stub_create(bypass, %{"id" => "s1"})

    assert {:ok, _conn} = ManagedAgents.open(open_opts(client, []), self())

    assert_received {:create_body, raw}
    assert raw == Jason.encode!(%{agent: "ag", environment_id: "env"})
  end

  test "a valid budget is sent in the documented shape", %{bypass: bypass, client: client} do
    stub_create(bypass, %{"id" => "s1", "budget" => @wire_budget})

    assert {:ok, _conn} =
             ManagedAgents.open(
               open_opts(client, budget: %{max_list_cost_cents: 125}),
               self()
             )

    assert_received {:create_body, raw}

    assert Jason.decode!(raw) == %{
             "agent" => "ag",
             "environment_id" => "env",
             "budget" => @wire_budget
           }
  end

  for {label, budget} <- [
        zero: %{max_list_cost_cents: 0},
        negative: %{max_list_cost_cents: -5},
        float: %{max_list_cost_cents: 12.5},
        string: %{max_list_cost_cents: "125"},
        missing_amount: %{},
        wrong_currency: %{max_list_cost_cents: 125, currency: "EUR"},
        wrong_type: %{max_list_cost_cents: 125, type: :soft},
        not_a_map: 125
      ] do
    test "an invalid budget (#{label}) is rejected before any request",
         %{bypass: bypass, client: client} do
      stub_create(bypass, %{"id" => "s1", "budget" => @wire_budget})

      assert {:error, {:invalid_opts, :budget}} =
               ManagedAgents.open(
                 open_opts(client, budget: unquote(Macro.escape(budget))),
                 self()
               )

      assert requests() == []
    end
  end

  test "a budget together with a session_id is rejected before any request",
       %{bypass: bypass, client: client} do
    stub_create(bypass, %{"id" => "s1", "budget" => @wire_budget})

    assert {:error, {:invalid_opts, :budget_with_session_id}} =
             ManagedAgents.open(
               open_opts(client, budget: %{max_list_cost_cents: 125}, session_id: "s1"),
               self()
             )

    assert requests() == []
  end

  test "a matching echo lets the session proceed", %{bypass: bypass, client: client} do
    stub_create(bypass, %{"id" => "s1", "budget" => @wire_budget})

    assert {:ok, %{session_id: "s1", consumer: task}} =
             ManagedAgents.open(
               open_opts(client, budget: %{max_list_cost_cents: 125}),
               self()
             )

    assert is_pid(task)
    assert {"GET", "/v1/sessions/s1/events/stream"} in requests()
  end

  for {label, echo} <- [
        absent: %{"id" => "s1"},
        null: %{"id" => "s1", "budget" => nil},
        different_amount: %{
          "id" => "s1",
          "budget" => %{
            "type" => "limit",
            "max_list_cost" => %{"amount" => "500", "currency" => "USD"}
          }
        }
      ] do
    test "an echo that is #{label} fails closed: no stream, no prompt, session archived",
         %{bypass: bypass, client: client} do
      stub_create(bypass, unquote(Macro.escape(echo)))

      assert {:error, {:budget_not_confirmed, %{session_id: "s1", archived: :ok}}} =
               ReqManagedAgents.run_to_completion(
                 client: client,
                 agent_id: "ag",
                 environment_id: "env",
                 prompt: "do not send me",
                 handler: fn _name, _input, _ctx -> {:ok, "x"} end,
                 budget: %{max_list_cost_cents: 125},
                 timeout: 2_000
               )

      seen = requests()
      assert {"POST", "/v1/sessions"} in seen
      refute {"POST", "/v1/sessions/s1/events"} in seen
      refute {"GET", "/v1/sessions/s1/events/stream"} in seen
      assert {"POST", "/v1/sessions/s1/archive"} in seen
    end
  end

  test "a spent budget surfaces as a terminated result with the provider's stop reason, session untouched",
       %{bypass: bypass, client: client} do
    stub_create(bypass, %{"id" => "s1", "budget" => @wire_budget})

    Bypass.stub(bypass, "GET", "/v1/sessions/s1/events/stream", fn conn ->
      Bypass.pass(bypass)
      conn = Plug.Conn.send_chunked(conn, 200)

      idle = %{"type" => "session.status_idle", "stop_reason" => %{"type" => "budget_reached"}}
      {:ok, conn} = Plug.Conn.chunk(conn, SSEFixtures.wire([idle]))
      Process.sleep(200)
      conn
    end)

    assert {:ok,
            %ReqManagedAgents.SessionResult{
              terminal: :terminated,
              stop_reason: %{"type" => "budget_reached"},
              session_id: "s1"
            }} =
             ReqManagedAgents.run_to_completion(
               client: client,
               agent_id: "ag",
               environment_id: "env",
               prompt: "go",
               handler: fn _name, _input, _ctx -> {:ok, "x"} end,
               budget: %{max_list_cost_cents: 125},
               timeout: 5_000
             )

    # The provider leaves a session at its budget idle; RMA does not archive it.
    refute {"POST", "/v1/sessions/s1/archive"} in requests()
  end

  test "a client built with retry: false makes one create attempt, as the Budget docs say",
       %{bypass: bypass} do
    test = self()

    Bypass.stub(bypass, "POST", "/v1/sessions", fn conn ->
      send(test, {:request, "POST", conn.request_path})
      Plug.Conn.resp(conn, 503, "{}")
    end)

    client =
      Client.new(
        api_key: "sk-test",
        base_url: "http://localhost:#{bypass.port}",
        req_options: [retry: false]
      )

    assert {:error, {:create_session_failed, {:http_error, 503, _}}} =
             ManagedAgents.open(open_opts(client, budget: %{max_list_cost_cents: 125}), self())

    assert requests() == [{"POST", "/v1/sessions"}]
  end

  describe "a non-confirmed echo with a failing archive" do
    setup %{bypass: bypass} do
      stub_create(bypass, %{"id" => "s1"})
      :ok
    end

    defp open_unconfirmed(client),
      do:
        :timer.tc(fn ->
          ManagedAgents.open(open_opts(client, budget: %{max_list_cost_cents: 125}), self())
        end)

    # Holds the handler open until the test releases it. Callers pass `Bypass.pass/1` first:
    # the client abandons the request, and Bypass would otherwise read the killed handler
    # as a failed expectation.
    defp hang(test) do
      send(test, {:hanging, self()})

      receive do
        :release -> :ok
      after
        15_000 -> :ok
      end
    end

    # The client has already given up, so the socket is gone by the time we reply.
    defp late_reply(conn) do
      Plug.Conn.resp(conn, 200, "{}")
    catch
      _kind, _reason -> conn
    end

    defp release_hanging do
      receive do
        {:hanging, pid} ->
          ref = Process.monitor(pid)
          send(pid, :release)

          receive do
            {:DOWN, ^ref, _, _, _} -> :ok
          after
            1_000 -> :ok
          end

          release_hanging()
      after
        0 -> :ok
      end
    end

    defp archive_posts, do: Enum.count(requests(), &(&1 == {"POST", "/v1/sessions/s1/archive"}))

    test "a 503 is tried once and the error carries the session id and the failure",
         %{bypass: bypass, client: client} do
      test = self()

      Bypass.stub(bypass, "POST", "/v1/sessions/s1/archive", fn conn ->
        send(test, {:request, "POST", conn.request_path})
        Plug.Conn.resp(conn, 503, "{}")
      end)

      {micros, result} = open_unconfirmed(client)

      assert {:error,
              {:budget_not_confirmed,
               %{session_id: "s1", echoed: nil, archived: {:error, {:http_error, 503, _}}}}} =
               result

      # Req's transient retry would add 1s before the second attempt.
      assert micros < 900_000
      assert archive_posts() == 1
    end

    test "a hanging archive is cut off at the client's receive timeout, once",
         %{bypass: bypass, client: client} do
      test = self()

      Bypass.stub(bypass, "POST", "/v1/sessions/s1/archive", fn conn ->
        send(test, {:request, "POST", conn.request_path})
        Bypass.pass(bypass)
        hang(test)
        late_reply(conn)
      end)

      client = %{client | receive_timeout: 300}
      {micros, result} = open_unconfirmed(client)

      assert {:error, {:budget_not_confirmed, %{session_id: "s1", archived: {:error, _}}}} =
               result

      assert micros < 1_500_000
      assert archive_posts() == 1
      release_hanging()
    end

    # One byte every `every_ms` keeps each read under the receive timeout, so only a deadline
    # on the whole attempt can end it.
    defp trickle(conn, every_ms, chunks) do
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce_while(1..chunks, conn, fn _, conn ->
        Process.sleep(every_ms)

        case Plug.Conn.chunk(conn, "x") do
          {:ok, conn} -> {:cont, conn}
          {:error, _closed} -> {:halt, conn}
        end
      end)
    end

    # A caller that traps exits (as Session does) must not find the archive's process in its
    # mailbox afterwards, whether it finished, failed or hit the deadline.
    # Messages the stubs send the test are expected; anything else is a stray.
    defp strays do
      {:messages, messages} = Process.info(self(), :messages)

      Enum.reject(messages, fn
        {:request, _method, _path} -> true
        {:create_body, _raw} -> true
        {:hanging, _pid} -> true
        _other -> false
      end)
    end

    test "the archive leaves nothing in an exit-trapping caller's mailbox on any path",
         %{bypass: bypass, client: client} do
      test = self()
      Process.flag(:trap_exit, true)

      Bypass.stub(bypass, "POST", "/v1/sessions/s1/archive", fn conn ->
        send(test, {:request, "POST", conn.request_path})
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert {_, {:error, {:budget_not_confirmed, %{archived: :ok}}}} = open_unconfirmed(client)
      Process.sleep(100)
      assert strays() == []

      Bypass.stub(bypass, "POST", "/v1/sessions/s1/archive", fn conn ->
        send(test, {:request, "POST", conn.request_path})
        Bypass.pass(bypass)
        trickle(conn, 100, 40)
      end)

      assert {_, {:error, {:budget_not_confirmed, %{archived: {:error, :archive_timeout}}}}} =
               open_unconfirmed(%{client | receive_timeout: 400})

      Process.sleep(100)
      assert strays() == []
    end

    test "a trickling archive is cut off by a total deadline, not just per-read timeouts",
         %{bypass: bypass, client: client} do
      test = self()

      Bypass.stub(bypass, "POST", "/v1/sessions/s1/archive", fn conn ->
        send(test, {:request, "POST", conn.request_path})
        Bypass.pass(bypass)
        trickle(conn, 100, 40)
      end)

      client = %{client | receive_timeout: 400}
      {micros, result} = open_unconfirmed(client)

      assert {:error,
              {:budget_not_confirmed, %{session_id: "s1", archived: {:error, :archive_timeout}}}} =
               result

      assert micros < 1_000_000
      assert archive_posts() == 1
    end

    test "with the default client a byte every 3 s is cut off at 5 s, not after 12 s",
         %{bypass: bypass, client: client} do
      test = self()

      Bypass.stub(bypass, "POST", "/v1/sessions/s1/archive", fn conn ->
        send(test, {:request, "POST", conn.request_path})
        Bypass.pass(bypass)
        trickle(conn, 3_000, 4)
      end)

      assert client.receive_timeout == 60_000
      {micros, result} = open_unconfirmed(client)

      assert {:error,
              {:budget_not_confirmed, %{session_id: "s1", archived: {:error, :archive_timeout}}}} =
               result

      assert micros in 4_500_000..5_500_000
      assert archive_posts() == 1
    end
  end
end
