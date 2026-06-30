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
end
