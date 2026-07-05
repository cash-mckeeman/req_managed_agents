defmodule ReqManagedAgents.Local.DepsTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Local.Deps

  test "ensure!/0 is :ok when req_llm is present (it is, in this repo's test env)" do
    assert Deps.ensure!() == :ok
  end
end
