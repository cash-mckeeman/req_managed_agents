defmodule ReqManagedAgents.Provisioner.StoreContractTest do
  use ExUnit.Case, async: true

  defmodule Contract do
    # Shared contract: call with an impl + a fresh store_opts factory.
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

  test "Store.ETS satisfies the contract" do
    table = :"store_contract_#{System.unique_integer([:positive])}"
    Contract.run(ReqManagedAgents.Provisioner.Store.ETS, table)
  end
end
