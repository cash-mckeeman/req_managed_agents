defmodule ReqManagedAgents.Provisioner.Environment.HandleTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Provisioner.Environment.Handle

  @atom_map %{environment_id: "e1", name: "d_abcd1234", digest: "abcd1234"}
  @string_map %{"environment_id" => "e1", "name" => "d_abcd1234", "digest" => "abcd1234"}

  test "new/1 absorbs an atom-keyed map" do
    assert %Handle{environment_id: "e1", name: "d_abcd1234", digest: "abcd1234"} =
             Handle.new(@atom_map)
  end

  test "new/1 absorbs a string-keyed map (the Store.File JSON round-trip shape)" do
    assert %Handle{environment_id: "e1", name: "d_abcd1234", digest: "abcd1234"} =
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
