defmodule ReqManagedAgents.ProvisionerTest do
  use ExUnit.Case, async: false
  alias ReqManagedAgents.Provisioner

  defmodule StubProvider do
    def provision(spec, opts), do: opts[:create_fun].(spec)
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
