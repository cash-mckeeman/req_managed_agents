defmodule ReqManagedAgents.Host.Store.ETSTest do
  use ExUnit.Case, async: true
  use ReqManagedAgents.Host.StoreConformance

  alias ReqManagedAgents.Host.Store.ETS

  setup do
    name = :"store_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ETS.start_link(name: name)

    {:ok, store_fixture: {ETS, name: name}}
  end
end
