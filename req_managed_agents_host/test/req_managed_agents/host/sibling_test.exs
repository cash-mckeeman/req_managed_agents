defmodule ReqManagedAgents.Host.SiblingTest do
  @moduledoc """
  The req_managed_agents dependency is the sibling directory in development,
  and a Hex requirement only when RMA_PUBLISH says so: "1" gives the family
  minor, "floor" pins the lowest version a requirement admits, and anything
  else, unset included, is the path. The first test reads the real project/0,
  so it sees exactly what Mix reads; the others drive `sibling/3` directly with
  versions whose patch is not zero.
  """
  use ExUnit.Case, async: false

  alias ReqManagedAgents.Host.Test.RMAPublishEnv

  @path {:req_managed_agents, path: "../req_managed_agents"}

  test "project/0 wires the sibling from its own version" do
    %Version{major: major, minor: minor} = Version.parse!(Mix.Project.config()[:version])
    family = "#{major}.#{minor}.0"

    assert deps_under(nil) == @path
    assert deps_under("0") == @path
    assert deps_under("1") == {:req_managed_agents, "~> " <> family}
    assert deps_under("floor") == {:req_managed_agents, "== " <> family}
  end

  test "publishing takes the family minor, not the exact version" do
    RMAPublishEnv.with_value("1", fn ->
      assert sibling("0.3.7") == {:req_managed_agents, "~> 0.3.0"}
      assert sibling("12.4.0") == {:req_managed_agents, "~> 12.4.0"}
    end)

    RMAPublishEnv.with_value("floor", fn ->
      assert sibling("0.3.7") == {:req_managed_agents, "== 0.3.0"}
    end)
  end

  test "a requirement overrides the family minor, and floor pins its lowest version" do
    RMAPublishEnv.with_value("1", fn ->
      assert sibling("0.3.7", "~> 0.3.2") == {:req_managed_agents, "~> 0.3.2"}
    end)

    RMAPublishEnv.with_value("floor", fn ->
      assert sibling("0.3.7", "~> 0.3.2") == {:req_managed_agents, "== 0.3.2"}
    end)
  end

  test "a floor requirement that is not a ~> requirement fails closed" do
    RMAPublishEnv.with_value("floor", fn ->
      assert_raise FunctionClauseError, fn -> sibling("0.3.7", "0.3.2") end
    end)
  end

  test "unset, the sibling is the path whatever the version" do
    RMAPublishEnv.with_value(nil, fn ->
      assert sibling("0.3.7") == @path
    end)
  end

  defp sibling(version, requirement \\ nil),
    do: Mix.Project.get!().sibling(:req_managed_agents, version, requirement)

  defp deps_under(value) do
    deps = RMAPublishEnv.with_value(value, fn -> Mix.Project.get!().project()[:deps] end)
    List.keyfind(deps, :req_managed_agents, 0)
  end
end
