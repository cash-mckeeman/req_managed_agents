defmodule ReqManagedAgents.Agent.HandleTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Agent.Handle

  @atom_map %{agent_id: "a1", name: "analyst_deadbeef", digest: "deadbeef"}
  @string_map %{"agent_id" => "a1", "name" => "analyst_deadbeef", "digest" => "deadbeef"}

  test "new/1 absorbs an atom-keyed map" do
    assert %Handle{agent_id: "a1", name: "analyst_deadbeef", digest: "deadbeef"} =
             Handle.new(@atom_map)
  end

  test "new/1 absorbs a string-keyed map (the Store.File JSON round-trip shape)" do
    assert %Handle{agent_id: "a1", name: "analyst_deadbeef", digest: "deadbeef"} =
             Handle.new(@string_map)
  end

  test "new/1 is idempotent on an existing %Handle{}" do
    handle = Handle.new(@atom_map)
    assert Handle.new(handle) == handle
  end

  test "@derive Jason.Encoder round-trips to the same three-field JSON object" do
    handle = Handle.new(@atom_map)
    encoded = Jason.encode!(handle)
    assert Jason.decode!(encoded) == @string_map
  end
end
