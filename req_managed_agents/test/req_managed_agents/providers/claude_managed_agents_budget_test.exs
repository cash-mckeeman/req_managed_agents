defmodule ReqManagedAgents.Providers.ClaudeManagedAgentsBudgetTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Client
  alias ReqManagedAgents.Providers.ClaudeManagedAgents, as: ManagedAgents

  @wire_budget %{
    "type" => "limit",
    "max_list_cost" => %{"amount" => "125", "currency" => "USD"}
  }

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

    Bypass.stub(bypass, "POST", "/v1/sessions/s1/archive", fn conn ->
      send(test, {:request, "POST", conn.request_path})
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

      assert {:error, {:budget_not_confirmed, _echoed}} =
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
end
