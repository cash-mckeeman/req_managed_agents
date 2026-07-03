defmodule ReqManagedAgents.StoreContract do
  @moduledoc false
  # Shared behaviour-contract assertions for Provisioner.Store implementations.
  # Lives in test/support (compiled before any test file) so test files can
  # reference it regardless of test-file compilation order — a nested module in
  # one test file is NOT reliably available to another under Elixir's
  # concurrent test compilation.
  import ExUnit.Assertions

  def run(impl, store_opts) do
    assert :miss = impl.get(store_opts, "provision:absent")
    assert :ok = impl.put(store_opts, "provision:k1", %{"id" => "a"})
    assert {:ok, %{"id" => "a"}} = impl.get(store_opts, "provision:k1")
    assert :ok = impl.put(store_opts, "provision:k1", %{"id" => "b"})
    assert {:ok, %{"id" => "b"}} = impl.get(store_opts, "provision:k1")
    assert :ok = impl.put(store_opts, "tag:base:prod", "deadbeef")
    assert {:ok, "deadbeef"} = impl.get(store_opts, "tag:base:prod")
    assert :ok = impl.delete(store_opts, "provision:k1")
    assert :miss = impl.get(store_opts, "provision:k1")
    assert :ok = impl.delete(store_opts, "provision:never-existed")
    assert :ok = impl.put(store_opts, "provision:k2", %{"id" => "victim"})
    assert :ok = impl.put(store_opts, "provision:k3", %{"id" => "survivor"})
    assert :ok = impl.delete_value(store_opts, %{"id" => "victim"})
    assert :miss = impl.get(store_opts, "provision:k2")
    assert {:ok, %{"id" => "survivor"}} = impl.get(store_opts, "provision:k3")
  end
end
