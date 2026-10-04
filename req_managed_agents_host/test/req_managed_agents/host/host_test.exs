defmodule ReqManagedAgents.Host.HostTest do
  @moduledoc """
  Integration matrix for `ReqManagedAgents.Host.send_message/3` — the whole public surface,
  exercised through `SessionSupervisor`/`Registry` the way a real caller would hit it.
  """
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Host
  alias ReqManagedAgents.Host.{Locator, SessionSupervisor}
  alias ReqManagedAgents.Host.Locator.Record
  alias ReqManagedAgents.Host.Store.{DETS, ETS}
  alias ReqManagedAgents.SessionResult

  @registry ReqManagedAgents.Host.Registry

  defp ets_store do
    name = :"host_test_ets_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ETS.start_link(name: name)
    {ETS, name: name}
  end

  defp base_opts(store), do: [provider: StubProvider, handler: EchoHandler, store: store]

  defp local_opts(store), do: [provider: StubLocalProvider, handler: EchoHandler, store: store]

  defp external_id, do: "ext-#{System.unique_integer([:positive])}"

  test "fresh: send_message returns {:ok, %SessionResult{}} and persists a locator record" do
    id = external_id()
    store = ets_store()

    assert {:ok, %SessionResult{session_id: sid}} =
             Host.send_message(id, "hello", base_opts(store))

    assert {:ok, %Record{session_id: ^sid}} = Locator.fetch(store, id)
  end

  test "reattach: a second send_message for the same external_id reuses the stored session_id" do
    id = external_id()
    store = ets_store()
    opts = base_opts(store)

    {:ok, %SessionResult{session_id: sid}} = Host.send_message(id, "first", opts)
    assert {:ok, %SessionResult{session_id: ^sid}} = Host.send_message(id, "second", opts)

    assert sid in StubProvider.opened_with()
    assert "second" in StubProvider.delivered_messages()
    # CMA-shaped regression guard: a server-held provider never emits a transcript, so
    # `history_opts/2` is always a no-op for it — nothing is ever stored to re-inject.
    assert :miss = Locator.fetch_transcript(store, id)
  end

  test "DETS-restart reattach: the locator survives a simulated BEAM restart (durability proof)" do
    id = external_id()
    name = :"host_test_dets_#{System.unique_integer([:positive])}"

    path =
      Path.join(System.tmp_dir!(), "rma_host_test_#{System.unique_integer([:positive])}.dets")

    on_exit(fn -> File.rm(path) end)

    {:ok, store_pid} = DETS.start_link(name: name, file: path)
    store = {DETS, name: name, file: path}
    opts = base_opts(store)

    assert {:ok, %SessionResult{session_id: sid}} = Host.send_message(id, "first", opts)

    # Simulate a restart: kill the live SessionServer through the real supervisor (not just
    # `kill`, so this exercises the same path production traffic would) and kill the DETS
    # store owner (closes the file) — nothing but the on-disk file survives.
    [{server_pid, nil}] = Registry.lookup(@registry, id)
    :ok = DynamicSupervisor.terminate_child(SessionSupervisor, server_pid)
    :ok = GenServer.stop(store_pid)

    # Reopen the DETS store from the same file — this is the "BEAM restart" for the locator.
    {:ok, _store_pid2} = DETS.start_link(name: name, file: path)

    assert {:ok, %SessionResult{session_id: ^sid}} = Host.send_message(id, "second", opts)
    assert sid in StubProvider.opened_with()
  end

  describe "transcript re-injection" do
    test "reattach injects the persisted transcript as history:" do
      id = external_id()
      store = ets_store()
      opts = local_opts(store)

      {:ok, %SessionResult{session_id: sid}} = Host.send_message(id, "first", opts)
      assert {:ok, %SessionResult{}} = Host.send_message(id, "second", opts)

      # `StubLocalProvider`'s `opened_with/0` recorder is a single global `Agent` shared by
      # every test (this module and others) that uses the stub, so under `async: true` other
      # modules' calls can interleave with ours — filter on `sid` (globally unique) rather
      # than assuming these are the only/last entries.
      assert {^sid, [_ | _] = injected} =
               Enum.find(StubLocalProvider.opened_with(), fn {opt_sid, _history} ->
                 opt_sid == sid
               end)

      assert Enum.any?(injected, &(&1["content"] == "first"))
    end

    test "the flagship-shaped proof: local conversation survives full restart over DETS" do
      id = external_id()
      name = :"host_test_dets_local_#{System.unique_integer([:positive])}"

      path =
        Path.join(
          System.tmp_dir!(),
          "rma_host_test_local_#{System.unique_integer([:positive])}.dets"
        )

      on_exit(fn -> File.rm(path) end)

      {:ok, store_pid} = DETS.start_link(name: name, file: path)
      store = {DETS, name: name, file: path}
      opts = local_opts(store)

      assert {:ok, %SessionResult{session_id: sid}} = Host.send_message(id, "first", opts)

      # Full restart: kill the live SessionServer through the real supervisor and the DETS
      # store owner (closes the file) — mirrors the DETS-restart reattach test above exactly,
      # just with the Local-shaped stub so the transcript re-injection path is exercised too.
      [{server_pid, nil}] = Registry.lookup(@registry, id)
      :ok = DynamicSupervisor.terminate_child(SessionSupervisor, server_pid)
      :ok = GenServer.stop(store_pid)

      # Reopen the DETS store from the same file — the "BEAM restart" for the locator.
      {:ok, _store_pid2} = DETS.start_link(name: name, file: path)

      assert {:ok, %SessionResult{}} = Host.send_message(id, "still there?", opts)

      assert {^sid, [_ | _] = injected} =
               Enum.find(StubLocalProvider.opened_with(), fn {opt_sid, _history} ->
                 opt_sid == sid
               end)

      assert Enum.any?(injected, &(&1["content"] == "first"))

      # And the stored transcript grew across the restart.
      assert {:ok, messages} = Locator.fetch_transcript(store, id)
      assert Enum.any?(messages, &(&1["content"] == "still there?"))
    end
  end

  test "isolation: two different external_ids run independently" do
    store = ets_store()
    opts = base_opts(store)
    id_a = external_id()
    id_b = external_id()

    assert {:ok, %SessionResult{session_id: sid_a}} = Host.send_message(id_a, "a", opts)
    assert {:ok, %SessionResult{session_id: sid_b}} = Host.send_message(id_b, "b", opts)

    refute sid_a == sid_b
    assert {:ok, %Record{session_id: ^sid_a}} = Locator.fetch(store, id_a)
    assert {:ok, %Record{session_id: ^sid_b}} = Locator.fetch(store, id_b)
  end

  test "config failure: missing required opts returns {:error, {:invalid_config, _}}" do
    assert {:error, {:invalid_config, _}} = Host.send_message("x", "hi", [])
  end

  test "Config timeout_ms threads through to the provider's :timeout opt (I1)" do
    id = external_id()
    store = ets_store()
    opts = Keyword.put(base_opts(store), :timeout_ms, 1_234)

    assert {:ok, %SessionResult{}} = Host.send_message(id, "hello", opts)

    assert 1_234 in StubProvider.opened_timeouts()
  end

  test "Config metadata persists into the Record and is reachable via Locator.list_by/2 (I2)" do
    id = external_id()
    store = ets_store()
    opts = Keyword.put(base_opts(store), :metadata, %{tenant: "acme"})

    assert {:ok, %SessionResult{}} = Host.send_message(id, "hello", opts)

    assert {:ok, %Record{metadata: %{tenant: "acme"}}} = Locator.fetch(store, id)
    assert [%Record{external_id: ^id}] = Locator.list_by(store, %{tenant: "acme"})
  end

  test "supervised idle-detach stops through the DynamicSupervisor and is NOT restarted (guards Step 0)" do
    id = external_id()
    store = ets_store()
    opts = Keyword.put(base_opts(store), :idle_timeout_ms, 20)

    assert {:ok, _result} = Host.send_message(id, "hi", opts)

    [{pid, nil}] = Registry.lookup(@registry, id)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500

    # If `SessionServer`'s child spec were left at the `use GenServer` default
    # (`restart: :permanent`), the `DynamicSupervisor` would restart it right here even
    # though the exit reason is `:normal` — give it a beat, then assert it did not.
    Process.sleep(50)
    assert Registry.lookup(@registry, id) == []
  end
end
