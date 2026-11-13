defmodule ReqManagedAgents.ProvisionerTest do
  use ExUnit.Case, async: false
  alias ReqManagedAgents.Provisioner

  defmodule StubProvider do
    def provision(spec, opts), do: opts[:create_fun].(spec)
  end

  defmodule CacheProbe do
    def get(owner, key) do
      send(owner, {:cache_read, key})
      :miss
    end

    def put(owner, key, _value) do
      send(owner, {:cache_write, key})
      :ok
    end
  end

  setup do
    Provisioner.reset()
    :ok
  end

  test "miss provisions once; hit returns cached ref without re-calling create" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    create = fn _spec ->
      Agent.update(counter, &(&1 + 1))
      {:ok, %{agent_id: "ag_1", environment_id: "env_1"}}
    end

    spec = %{
      system_prompt: "sys",
      tools: [%{"name" => "t"}],
      terminal_tool: "t",
      model_config: "claude-sonnet-4-6"
    }

    assert {:ok, %{agent_id: "ag_1", environment_id: "env_1"}} =
             Provisioner.ensure(StubProvider, spec, create_fun: create)

    assert {:ok, %{agent_id: "ag_1", environment_id: "env_1"}} =
             Provisioner.ensure(StubProvider, spec, create_fun: create)

    assert Agent.get(counter, & &1) == 1
  end

  test "a changed spec re-provisions (different hash)" do
    create = fn _ ->
      {:ok, %{agent_id: "ag_#{:erlang.unique_integer([:positive])}", environment_id: "env"}}
    end

    s1 = %{system_prompt: "a", tools: [], terminal_tool: nil, model_config: "claude-sonnet-4-6"}
    s2 = %{s1 | system_prompt: "b"}
    assert {:ok, %{agent_id: a1}} = Provisioner.ensure(StubProvider, s1, create_fun: create)
    assert {:ok, %{agent_id: a2}} = Provisioner.ensure(StubProvider, s2, create_fun: create)
    refute a1 == a2
  end

  test "the same spec in the same :cache_scope reuses the handle" do
    opts = counted_options()

    assert {:ok, first} =
             ReqManagedAgents.provision(
               StubProvider,
               scope_spec(),
               [cache_scope: "authority-a"] ++ opts
             )

    assert {:ok, ^first} =
             ReqManagedAgents.provision(
               StubProvider,
               scope_spec(),
               [cache_scope: "authority-a"] ++ opts
             )

    assert_received {:created, 1}
    refute_received {:created, 2}
  end

  test "the same spec in a different :cache_scope provisions again" do
    opts = counted_options()

    assert {:ok, %{agent_id: 1}} =
             ReqManagedAgents.provision(
               StubProvider,
               scope_spec(),
               [cache_scope: "authority-a"] ++ opts
             )

    assert {:ok, %{agent_id: 2}} =
             ReqManagedAgents.provision(
               StubProvider,
               scope_spec(),
               [cache_scope: "authority-b"] ++ opts
             )
  end

  test "scoped and unscoped handles for the same spec stay separate" do
    opts = counted_options()
    assert {:ok, %{agent_id: 1}} = Provisioner.ensure(StubProvider, scope_spec(), opts)

    assert {:ok, %{agent_id: 2}} =
             Provisioner.ensure(StubProvider, scope_spec(), [cache_scope: "authority-a"] ++ opts)

    assert {:ok, %{agent_id: 1}} = Provisioner.ensure(StubProvider, scope_spec(), opts)
  end

  test "an invalid :cache_scope errors before any store or provider access" do
    opts = [store: {CacheProbe, self()}] ++ counted_options()

    for value <- [nil, "", 7, :authority, %{}] do
      assert {:error, {:invalid_opts, :cache_scope}} =
               ReqManagedAgents.provision(
                 StubProvider,
                 scope_spec(),
                 [cache_scope: value] ++ opts
               )
    end

    refute_received {:created, _}
    refute_received {:cache_read, _}
    refute_received {:cache_write, _}

    assert {:ok, _} =
             ReqManagedAgents.provision(
               StubProvider,
               scope_spec(),
               [cache_scope: "valid"] ++ opts
             )

    assert_received {:cache_read, _}
    assert_received {:cache_write, _}
  end

  # Persisted stores (Store.File) hold handles under this key; changing it for
  # unscoped calls would re-provision every existing handle on upgrade.
  test "an omitted :cache_scope keeps the existing cache key" do
    opts = [store: {CacheProbe, self()}] ++ counted_options()

    assert {:ok, _} = Provisioner.ensure(StubProvider, scope_spec(), opts)

    key = "provision:" <> Provisioner.hash({StubProvider, scope_spec()})
    assert_received {:cache_read, ^key}
    assert_received {:cache_write, ^key}
  end

  test "environment identity still separates handles within one :cache_scope" do
    opts = [cache_scope: "authority-a"] ++ counted_options()

    assert {:ok, %{agent_id: 1}} =
             Provisioner.ensure(
               StubProvider,
               scope_spec(),
               [environment: %{config: %{"x" => 1}}] ++ opts
             )

    assert {:ok, %{agent_id: 2}} =
             Provisioner.ensure(
               StubProvider,
               scope_spec(),
               [environment: %{config: %{"x" => 2}}] ++ opts
             )

    assert {:ok, %{agent_id: 1}} =
             Provisioner.ensure(
               StubProvider,
               scope_spec(),
               [environment: %{config: %{"x" => 1}}] ++ opts
             )
  end

  defp counted_options do
    owner = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    [
      create_fun: fn _ ->
        id = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
        send(owner, {:created, id})
        {:ok, %{agent_id: id}}
      end
    ]
  end

  defp scope_spec, do: %{system_prompt: "scope", tools: [], terminal_tool: nil, model_config: "m"}

  # --- #70/#72: environment is back in the Layer-B cache key -------------------------------
  #
  # Regression guard: T3 moved environment to bare opts, which never entered the cache key —
  # two provisions of the SAME Agent.Spec into DIFFERENT environments collided on one key and
  # wrongly reused the first handle. This proves the fix at the Provisioner layer (Layer B);
  # the Bedrock harness_name test proves it at Layer A.
  test "same spec + different Environment.Spec → different cache keys (env collision fix); env-less unchanged" do
    create = fn _ ->
      {:ok, %{agent_id: :erlang.unique_integer([:positive])}}
    end

    spec = %{system_prompt: "a", tools: [], terminal_tool: nil, model_config: "m"}

    # Env-less: two calls share one key → provision once, same handle (byte-identical key).
    assert {:ok, %{agent_id: none1}} = Provisioner.ensure(StubProvider, spec, create_fun: create)
    assert {:ok, %{agent_id: none2}} = Provisioner.ensure(StubProvider, spec, create_fun: create)
    assert none1 == none2

    env_a = %{config: %{"x" => 1}}
    env_b = %{config: %{"x" => 2}}

    assert {:ok, %{agent_id: a}} =
             Provisioner.ensure(StubProvider, spec, create_fun: create, environment: env_a)

    assert {:ok, %{agent_id: b}} =
             Provisioner.ensure(StubProvider, spec, create_fun: create, environment: env_b)

    # Different environments no longer collide, and neither collides with the env-less handle.
    refute a == b
    refute a == none1
    refute b == none1
  end

  test "an Environment.Spec differing only by name shares the cache key (name excluded from digest)" do
    create = fn _ -> {:ok, %{agent_id: :erlang.unique_integer([:positive])}} end
    spec = %{system_prompt: "a", tools: [], terminal_tool: nil, model_config: "m"}

    env1 = %{name: "one", config: %{"x" => 1}}
    env2 = %{name: "two", config: %{"x" => 1}}

    assert {:ok, %{agent_id: h1}} =
             Provisioner.ensure(StubProvider, spec, create_fun: create, environment: env1)

    assert {:ok, %{agent_id: h2}} =
             Provisioner.ensure(StubProvider, spec, create_fun: create, environment: env2)

    assert h1 == h2
  end

  test "an invalid Environment.Spec surfaces {:error, :invalid_environment_spec} rather than caching a bad key" do
    spec = %{system_prompt: "a", tools: [], terminal_tool: nil, model_config: "m"}

    assert {:error, :invalid_environment_spec} =
             Provisioner.ensure(StubProvider, spec,
               environment: %{runtimes: [%{lang: :python}]},
               create_fun: fn _ -> {:ok, %{agent_id: "should_not_be_reached"}} end
             )
  end
end
