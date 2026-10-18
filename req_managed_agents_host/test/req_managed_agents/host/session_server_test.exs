defmodule ReqManagedAgents.Host.SessionServerTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Host.{Config, Locator, Locator.Record, SessionServer}
  alias ReqManagedAgents.Host.Store.ETS
  alias ReqManagedAgents.SessionResult

  # ReqManagedAgents.Host.Registry is started by ReqManagedAgents.Host.Application (mix.exs
  # `mod:`), which Mix boots automatically for `mix test` — no manual Registry start needed here.

  defp ets_store do
    name = :"session_server_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ETS.start_link(name: name)
    {ETS, name: name}
  end

  test "first message creates a session and persists session_id to the locator" do
    {:ok, cfg} =
      Config.new(
        provider: StubProvider,
        handler: EchoHandler,
        store: ets_store(),
        idle_timeout_ms: 50
      )

    {:ok, pid} = SessionServer.start_link({"thread-1", cfg})

    assert {:ok, %SessionResult{session_id: sid}} = SessionServer.deliver(pid, "hello")
    assert {:ok, %Record{session_id: ^sid}} = Locator.fetch(cfg.store, "thread-1")
  end

  test "reattach passes the stored session_id back into Session.run (not a fresh create)" do
    {:ok, cfg} = Config.new(provider: StubProvider, handler: EchoHandler, store: ets_store())
    {:ok, pid} = SessionServer.start_link({"thread-2", cfg})

    {:ok, %SessionResult{session_id: sid}} = SessionServer.deliver(pid, "first")
    {:ok, _} = SessionServer.deliver(pid, "second")

    assert sid in StubProvider.opened_with()
    assert "second" in StubProvider.delivered_messages()
  end

  test "a budget in provider_opts is passed on the fresh turn only" do
    {:ok, cfg} =
      Config.new(
        provider: StubProvider,
        handler: EchoHandler,
        store: ets_store(),
        provider_opts: [budget: %{max_list_cost_cents: 125}]
      )

    {:ok, pid} = SessionServer.start_link({"thread-budget", cfg})

    {:ok, %SessionResult{session_id: sid}} = SessionServer.deliver(pid, "first")
    {:ok, _} = SessionServer.deliver(pid, "second")

    assert [{^sid, %{max_list_cost_cents: 125}}, {^sid, nil}] =
             Enum.filter(StubProvider.opened_budgets(), &match?({^sid, _}, &1))
  end

  test "idle-detach stops the server but the locator row survives" do
    {:ok, cfg} =
      Config.new(
        provider: StubProvider,
        handler: EchoHandler,
        store: ets_store(),
        idle_timeout_ms: 20
      )

    {:ok, pid} = SessionServer.start_link({"thread-3", cfg})
    ref = Process.monitor(pid)

    {:ok, _} = SessionServer.deliver(pid, "hi")

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    assert {:ok, %Record{}} = Locator.fetch(cfg.store, "thread-3")
  end

  describe "transcript persistence" do
    test "a provider emitting a transcript gets it stored under {:transcript, external_id}" do
      {:ok, cfg} =
        Config.new(provider: StubLocalProvider, handler: EchoHandler, store: ets_store())

      {:ok, pid} = SessionServer.start_link({"thread-4", cfg})

      assert {:ok, %SessionResult{}} = SessionServer.deliver(pid, "hello")

      assert {:ok, [_ | _] = messages} = Locator.fetch_transcript(cfg.store, "thread-4")
      assert Enum.any?(messages, &(&1["content"] == "hello"))
    end

    test "a provider without transcript/1 stores nothing (CMA-shaped no-op)" do
      {:ok, cfg} = Config.new(provider: StubProvider, handler: EchoHandler, store: ets_store())
      {:ok, pid} = SessionServer.start_link({"thread-5", cfg})

      assert {:ok, %SessionResult{}} = SessionServer.deliver(pid, "hello")

      assert :miss = Locator.fetch_transcript(cfg.store, "thread-5")
    end
  end

  test "each Host caller receives its own partial result before error without advancing the store" do
    alias ReqManagedAgents.Host
    alias ReqManagedAgents.Providers.Local

    test_pid = self()
    store = ets_store()
    external_id = "partial-#{System.unique_integer([:positive])}"
    supervisor = start_supervised!(Task.Supervisor)

    chat = fn request ->
      send(test_pid, {:chat, request.messages})
      prompt = request.messages |> Enum.filter(&(&1["role"] == "user")) |> List.last()

      cond do
        List.last(request.messages)["role"] == "tool" ->
          {:error, :host_transport_down}

        prompt["content"] == "seed" ->
          {:ok, host_response(1, false)}

        true ->
          tokens = if prompt["content"] == "first", do: 12, else: 24
          {:ok, host_response(tokens, true)}
      end
    end

    opts = [
      provider: Local,
      handler: EchoHandler,
      store: store,
      provider_opts: [chat_fun: chat, max_chat_retries: 0, model_config: %{model: "test-model"}]
    ]

    on_exit(fn ->
      case Registry.lookup(ReqManagedAgents.Host.Registry, external_id) do
        [{pid, _}] ->
          DynamicSupervisor.terminate_child(ReqManagedAgents.Host.SessionSupervisor, pid)

        [] ->
          :ok
      end
    end)

    assert {{:ok, %SessionResult{session_id: sid}}, _, []} =
             host_call(supervisor, external_id, "seed", opts)

    baseline = [
      %{"role" => "user", "content" => "seed"},
      %{"role" => "assistant", "content" => "seed-reply"}
    ]

    assert {:ok, ^baseline} = Locator.fetch_transcript(store, external_id)
    assert {:ok, record} = Locator.fetch(store, external_id)
    assert_receive {:chat, [%{"role" => "user", "content" => "seed"}]}

    for {prompt, tokens} <- [{"first", 12}, {"second", 24}] do
      assert {{:error, :host_transport_down}, result, []} =
               host_call(supervisor, external_id, prompt, opts)

      assert %SessionResult{} = result
      assert result.session_id == sid
      assert result.terminal == :terminated
      assert result.in_flight == :unknown
      assert result.turns == 1
      assert result.usage.input_tokens == tokens
      assert result.usage.output_tokens == 4
      assert result.usage.cache_read_input_tokens == 3
      assert result.usage.cache_creation_input_tokens == 2
      assert result.usage.input_token_basis == :uncached
      assert result.usage.complete?
      assert result.stop_reason == "tool_calls"
      assert Enum.any?(result.transcript, &(&1["content"] == "partial"))
      assert {:ok, ^record} = Locator.fetch(store, external_id)
      assert {:ok, ^baseline} = Locator.fetch_transcript(store, external_id)
      assert_receive {:chat, [first, second, %{"role" => "user", "content" => ^prompt}]}
      assert [first, second] == baseline
      assert_receive {:chat, messages}
      assert List.last(messages)["role"] == "tool"
    end

    cleared = put_in(opts, [:provider_opts, :notify], nil)
    assert {:error, :host_transport_down} = Host.send_message(external_id, "unobserved", cleared)
    refute_receive {:managed_agents_session, _}
    assert {:ok, ^baseline} = Locator.fetch_transcript(store, external_id)
  end

  defp host_call(supervisor, external_id, prompt, opts) do
    Task.Supervisor.async_nolink(supervisor, fn ->
      opts = put_in(opts, [:provider_opts, :notify], self())
      returned = ReqManagedAgents.Host.send_message(external_id, prompt, opts)
      result = receive do: ({:managed_agents_session, result} -> result), after: (0 -> :missing)
      {returned, result, host_residue()}
    end)
    |> Task.await(2_000)
  end

  defp host_residue do
    receive do
      {:managed_agents_session, result} -> [result | host_residue()]
    after
      0 -> []
    end
  end

  defp host_response(tokens, tool?) do
    message =
      if tool? do
        %{
          "role" => "assistant",
          "content" => "partial",
          "tool_calls" => [
            %{"id" => "tool", "function" => %{"name" => "echo", "arguments" => "{}"}}
          ]
        }
      else
        %{"role" => "assistant", "content" => "seed-reply"}
      end

    %{
      "choices" => [
        %{"message" => message, "finish_reason" => if(tool?, do: "tool_calls", else: "stop")}
      ],
      "usage" => %{
        "prompt_tokens" => tokens,
        "completion_tokens" => 4,
        "input_token_basis" => "uncached",
        "prompt_tokens_details" => %{"cached_tokens" => 3, "cache_write_tokens" => 2}
      }
    }
  end
end
