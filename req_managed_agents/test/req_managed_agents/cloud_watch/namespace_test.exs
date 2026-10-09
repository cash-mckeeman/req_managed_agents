defmodule ReqManagedAgents.CloudWatch.NamespaceTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.CloudWatch.{Client, Evidence, Query}
  alias ReqManagedAgents.Evidence.Error

  test "service entrypoints reject absent destination and capture inputs" do
    assert {:error, %Error{}} = Client.new([])
    assert {:error, %Error{}} = Query.new(%{})
    assert {:error, %Error{}} = Evidence.enrich(nil, nil, nil, [])
  end
end
