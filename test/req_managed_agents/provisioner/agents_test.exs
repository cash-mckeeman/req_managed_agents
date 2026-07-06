defmodule ReqManagedAgents.Provisioner.AgentsTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Provisioner.Agents

  @spec_attrs %{
    name: "analyst",
    system_prompt: "s",
    tools: [],
    terminal_tool: "submit",
    model_config: "m"
  }

  # A fresh ETS table per test → isolation without HTTP.
  defp store(ctx), do: {ReqManagedAgents.Provisioner.Store.ETS, :"agents_#{ctx.test}"}

  defp counting_create(agent, id) do
    fn body ->
      Agent.update(agent, &[body | &1])
      {:ok, %{"id" => id}}
    end
  end

  setup ctx do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    {:ok, store: store(ctx), calls: calls}
  end

  test "provisions once and returns the three-field handle", %{store: store, calls: calls} do
    assert {:ok, %{agent_id: "agent_1", name: name, digest: digest}} =
             Agents.ensure_agent(nil, @spec_attrs,
               store: store,
               create_fun: counting_create(calls, "agent_1")
             )

    assert name == "analyst_" <> digest
    assert digest =~ ~r/^[0-9a-f]{8}$/
    assert [%{name: ^name, model: "m", system: "s", tools: []}] = Agent.get(calls, & &1)
  end

  test "second ensure hits the store — create_fun not called again", %{store: store, calls: calls} do
    create = counting_create(calls, "agent_1")
    {:ok, h1} = Agents.ensure_agent(nil, @spec_attrs, store: store, create_fun: create)
    {:ok, h2} = Agents.ensure_agent(nil, @spec_attrs, store: store, create_fun: create)

    assert h1 == h2
    assert length(Agent.get(calls, & &1)) == 1, "create_fun ran exactly once"
  end
end
