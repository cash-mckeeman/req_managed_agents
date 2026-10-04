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
end
