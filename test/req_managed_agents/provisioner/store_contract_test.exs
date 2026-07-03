defmodule ReqManagedAgents.Provisioner.StoreContractTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.StoreContract

  test "Store.ETS satisfies the contract" do
    table = :"store_contract_#{System.unique_integer([:positive])}"
    StoreContract.run(ReqManagedAgents.Provisioner.Store.ETS, table)
  end
end
