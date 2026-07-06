defmodule ReqManagedAgents.ConfigTest do
  use ExUnit.Case, async: false
  alias ReqManagedAgents.Config

  test "resolve/4 prefers opts, then app env, then env var, then default" do
    System.put_env("RMA_TEST_KEY", "from_env")

    on_exit(fn ->
      System.delete_env("RMA_TEST_KEY")
      Application.delete_env(:req_managed_agents, :rma_test)
    end)

    assert Config.resolve([rma_test: "from_opts"], :rma_test, "RMA_TEST_KEY", "d") == "from_opts"
    Application.put_env(:req_managed_agents, :rma_test, "from_app")
    assert Config.resolve([], :rma_test, "RMA_TEST_KEY", "d") == "from_app"
    Application.delete_env(:req_managed_agents, :rma_test)
    assert Config.resolve([], :rma_test, "RMA_TEST_KEY", "d") == "from_env"
    System.delete_env("RMA_TEST_KEY")
    assert Config.resolve([], :rma_test, "RMA_TEST_KEY", "d") == "d"
  end

  test "resolve!/3 raises a clear error when all layers miss" do
    assert_raise RuntimeError, ~r/RMA_MISSING/, fn ->
      Config.resolve!([], :rma_missing, "RMA_MISSING")
    end
  end

  test "resolve/4 is presence-based: a falsy app-env value still wins over the default" do
    Application.put_env(:req_managed_agents, :some_flag, false)
    on_exit(fn -> Application.delete_env(:req_managed_agents, :some_flag) end)

    assert Config.resolve([], :some_flag, "NOPE", "default_val") == false
  end
end
