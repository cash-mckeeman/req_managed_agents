defmodule ReqManagedAgents.Host.SiblingTest do
  @moduledoc """
  The req_managed_agents dependency is the sibling directory in development,
  and a Hex requirement only when RMA_PUBLISH says so: "1" gives the family
  minor, "floor" pins that minor's lowest version, and anything else, unset
  included, is the path. Evaluated through the real project/0, so the test
  reads exactly what Mix reads.
  """
  use ExUnit.Case, async: false

  alias ReqManagedAgents.Host.Test.RMAPublishEnv

  test "each RMA_PUBLISH value resolves the sibling as specified" do
    %Version{major: major, minor: minor} = Version.parse!(Mix.Project.config()[:version])
    family = "#{major}.#{minor}.0"
    path = {:req_managed_agents, path: "../req_managed_agents"}

    assert sibling_under(nil) == path
    assert sibling_under("0") == path
    assert sibling_under("1") == {:req_managed_agents, "~> " <> family}
    assert sibling_under("floor") == {:req_managed_agents, "== " <> family}
  end

  test "the family minor drops the patch, and is not the exact version" do
    project = Mix.Project.get!()

    assert project.family_minor("0.3.7") == "~> 0.3.0"
    assert project.family_minor("12.4.0") == "~> 12.4.0"
  end

  defp sibling_under(value) do
    deps = RMAPublishEnv.with_value(value, fn -> Mix.Project.get!().project()[:deps] end)
    List.keyfind(deps, :req_managed_agents, 0)
  end
end
