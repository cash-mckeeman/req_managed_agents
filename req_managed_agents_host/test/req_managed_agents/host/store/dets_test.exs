defmodule ReqManagedAgents.Host.Store.DETSTest do
  use ExUnit.Case, async: true
  use ReqManagedAgents.Host.StoreConformance

  alias ReqManagedAgents.Host.Store.DETS

  setup do
    name = :"store_test_#{System.unique_integer([:positive])}"

    path =
      Path.join(System.tmp_dir!(), "rma_host_dets_#{System.unique_integer([:positive])}.dets")

    {:ok, _pid} = DETS.start_link(name: name, file: path)

    on_exit(fn ->
      File.rm(path)
    end)

    {:ok, store_fixture: {DETS, name: name, file: path}}
  end

  test "DETS locator survives a simulated BEAM restart" do
    path =
      Path.join(System.tmp_dir!(), "rma_host_restart_#{System.unique_integer([:positive])}.dets")

    on_exit(fn -> File.rm(path) end)

    name = :"restart_t_#{System.unique_integer([:positive])}"

    {:ok, pid1} = DETS.start_link(name: name, file: path)
    ref = DETS.ref(name: name, file: path)
    :ok = DETS.put(ref, "thread-42", %{session_id: "sess-1"})
    :ok = GenServer.stop(pid1)

    {:ok, _pid2} = DETS.start_link(name: name, file: path)

    assert {:ok, %{session_id: "sess-1"}} =
             DETS.get(DETS.ref(name: name, file: path), "thread-42")
  end
end
