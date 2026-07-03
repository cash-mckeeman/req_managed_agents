defmodule ReqManagedAgents.Provisioner.StoreFileTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias ReqManagedAgents.Provisioner.Store
  alias ReqManagedAgents.Provisioner.StoreContractTest.Contract

  setup do
    dir = System.tmp_dir!() |> Path.join("rma_store_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, path: Path.join(dir, "provisions.json")}
  end

  test "satisfies the store contract", %{path: path} do
    Contract.run(Store.File, path: path)
  end

  test "persists across store instances (fresh-OS-process simulation)", %{path: path} do
    assert :ok = Store.File.put([path: path], "provision:h1", %{"environment_id" => "env_1"})
    # A "new process" is just a new call with the same path — nothing in-memory.
    assert {:ok, %{"environment_id" => "env_1"}} = Store.File.get([path: path], "provision:h1")
  end

  test "missing file is empty, not an error", %{path: path} do
    assert :miss = Store.File.get([path: path], "provision:none")
  end

  test "corrupt file is treated as empty with a logged warning", %{path: path} do
    File.write!(path, "{not json!!")

    log =
      capture_log(fn ->
        assert :miss = Store.File.get([path: path], "provision:x")
      end)

    assert log =~ "corrupt"
    # And a subsequent put recovers the file.
    assert :ok = Store.File.put([path: path], "provision:x", %{"a" => 1})
    assert {:ok, %{"a" => 1}} = Store.File.get([path: path], "provision:x")
  end

  test "writes are atomic — no partial JSON visible at the path", %{path: path} do
    for i <- 1..50, do: :ok = Store.File.put([path: path], "provision:k#{i}", %{"i" => i})
    # If writes were non-atomic, an interleaved reader could see partial JSON;
    # at minimum the final file must parse and hold all keys.
    assert {:ok, %{"i" => 50}} = Store.File.get([path: path], "provision:k50")
    assert {:ok, %{"i" => 1}} = Store.File.get([path: path], "provision:k1")
    assert {:ok, _} = Jason.decode(File.read!(path))
  end
end
