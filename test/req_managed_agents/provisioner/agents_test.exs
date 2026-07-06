defmodule ReqManagedAgents.Provisioner.AgentsTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Agent.Spec
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

  @conflict {:error, {:http_error, 409, "exists"}}

  test "409 recovers by name when a live agent matches", %{store: store} do
    {:ok, %{name: name, digest: digest}} =
      Agents.ensure_agent(nil, @spec_attrs,
        store: store,
        create_fun: fn _ -> {:ok, %{"id" => "seed"}} end
      )

    store2 =
      {ReqManagedAgents.Provisioner.Store.ETS,
       :"agents_recover_#{System.unique_integer([:positive])}"}

    live_list = fn ->
      {:ok, %{"data" => [%{"id" => "live_1", "name" => name, "archived_at" => nil}]}}
    end

    assert {:ok, %{agent_id: "live_1", name: ^name, digest: ^digest}} =
             Agents.ensure_agent(nil, @spec_attrs,
               store: store2,
               create_fun: fn _ -> @conflict end,
               list_fun: live_list
             )
  end

  test "409 with an archived name is an error", %{store: store} do
    {:ok, %{name: name}} =
      Agents.ensure_agent(nil, @spec_attrs,
        store: store,
        create_fun: fn _ -> {:ok, %{"id" => "seed"}} end
      )

    store2 =
      {ReqManagedAgents.Provisioner.Store.ETS,
       :"agents_arch_#{System.unique_integer([:positive])}"}

    archived = fn ->
      {:ok, %{"data" => [%{"id" => "x", "name" => name, "archived_at" => "2026-01-01"}]}}
    end

    assert {:error, {:agent_archived, ^name}} =
             Agents.ensure_agent(nil, @spec_attrs,
               store: store2,
               create_fun: fn _ -> @conflict end,
               list_fun: archived
             )
  end

  test "409 with no matching name is a conflict", %{store: store} do
    unrelated = fn ->
      {:ok, %{"data" => [%{"id" => "y", "name" => "other_deadbeef", "archived_at" => nil}]}}
    end

    assert {:error, {:agent_name_conflict, _name}} =
             Agents.ensure_agent(nil, @spec_attrs,
               store: store,
               create_fun: fn _ -> @conflict end,
               list_fun: unrelated
             )
  end

  test "a string-keyed stored handle is re-atomized on the next ensure", %{store: store} do
    {:ok, %{name: name, digest: digest}} =
      Agents.ensure_agent(nil, @spec_attrs,
        store: store,
        create_fun: fn _ -> {:ok, %{"id" => "a1"}} end
      )

    {smod, sopts} = store
    key = "provision:agent:" <> ReqManagedAgents.Provisioner.hash({"analyst", digest})
    smod.put(sopts, key, %{"agent_id" => "a1", "name" => name, "digest" => digest})

    assert {:ok, %{agent_id: "a1", name: ^name, digest: ^digest}} =
             Agents.ensure_agent(nil, @spec_attrs,
               store: store,
               create_fun: fn _ -> flunk("should hit store") end
             )
  end

  test "a foreign-shape store entry is a miss and rebuilds", %{store: store} do
    {smod, sopts} = store
    {:ok, spec} = Spec.new(@spec_attrs)
    digest = Spec.digest(spec)
    key = "provision:agent:" <> ReqManagedAgents.Provisioner.hash({"analyst", digest})
    smod.put(sopts, key, %{"junk" => true})

    assert {:ok, %{agent_id: "rebuilt"}} =
             Agents.ensure_agent(nil, @spec_attrs,
               store: store,
               create_fun: fn _ -> {:ok, %{"id" => "rebuilt"}} end
             )
  end

  test "tag then resolve returns the handle; unknown tag and pruned digest error; no-colon raises",
       %{store: store} do
    {:ok, %{digest: _digest} = handle} =
      Agents.ensure_agent(nil, @spec_attrs,
        store: store,
        create_fun: fn _ -> {:ok, %{"id" => "a1"}} end
      )

    assert :ok = Agents.tag_agent("analyst", "prod", handle, store: store)
    assert {:ok, ^handle} = Agents.resolve_agent("analyst:prod", store: store)

    assert {:error, :unknown_tag} = Agents.resolve_agent("analyst:staging", store: store)

    assert :ok = Agents.tag_agent("analyst", "ghost", "00000000", store: store)

    assert {:error, {:untracked_digest, "00000000"}} =
             Agents.resolve_agent("analyst:ghost", store: store)

    assert_raise ArgumentError, fn -> Agents.resolve_agent("no-colon", store: store) end
  end

  defp agent_row(base, digest, created),
    do: %{
      "id" => "id_" <> digest,
      "name" => base <> "_" <> digest,
      "archived_at" => nil,
      "created_at" => created
    }

  test "keeps newest N, archives the rest oldest-first, protects tagged, requires keep", %{
    store: store
  } do
    base = "analyst"

    rows = [
      agent_row(base, "aaaaaaaa", 3),
      agent_row(base, "bbbbbbbb", 2),
      agent_row(base, "cccccccc", 1)
    ]

    list = fn -> {:ok, %{"data" => rows}} end
    {:ok, archived} = Agent.start_link(fn -> [] end)

    archive = fn id ->
      Agent.update(archived, &[id | &1])
      {:ok, %{}}
    end

    :ok = Agents.tag_agent(base, "prod", "cccccccc", store: store)

    assert {:error, :keep_required} =
             Agents.prune_agents(nil, base, store: store, list_fun: list, archive_fun: archive)

    assert {:ok, %{archived: ["analyst_bbbbbbbb"], kept: kept}} =
             Agents.prune_agents(nil, base,
               keep: 1,
               store: store,
               list_fun: list,
               archive_fun: archive
             )

    assert "analyst_aaaaaaaa" in kept and "analyst_cccccccc" in kept
    assert Agent.get(archived, & &1) == ["id_bbbbbbbb"]
  end

  test "with 3+ untagged versions, archives strictly oldest-first and keeps only the newest", %{
    store: store
  } do
    base = "analyst"

    rows = [
      agent_row(base, "aaaaaaaa", 3),
      agent_row(base, "bbbbbbbb", 2),
      agent_row(base, "cccccccc", 1)
    ]

    list = fn -> {:ok, %{"data" => rows}} end
    {:ok, call_order} = Agent.start_link(fn -> [] end)

    archive = fn id ->
      Agent.update(call_order, &(&1 ++ [id]))
      {:ok, %{}}
    end

    assert {:ok, %{archived: archived, kept: kept}} =
             Agents.prune_agents(nil, base,
               keep: 1,
               store: store,
               list_fun: list,
               archive_fun: archive
             )

    assert kept == ["analyst_aaaaaaaa"]
    assert archived == ["analyst_cccccccc", "analyst_bbbbbbbb"]
    assert Agent.get(call_order, & &1) == ["id_cccccccc", "id_bbbbbbbb"]
  end

  test "a failure archiving the second-oldest returns a partial result naming both lists", %{
    store: store
  } do
    base = "analyst"

    rows = [
      agent_row(base, "aaaaaaaa", 3),
      agent_row(base, "bbbbbbbb", 2),
      agent_row(base, "cccccccc", 1)
    ]

    list = fn -> {:ok, %{"data" => rows}} end
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    reason = {:http_error, 500, "boom"}

    archive = fn _id ->
      n = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})

      if n == 1 do
        {:ok, %{}}
      else
        {:error, reason}
      end
    end

    assert {:error, {:partial, ["analyst_cccccccc"], {"analyst_bbbbbbbb", ^reason}}} =
             Agents.prune_agents(nil, base,
               keep: 1,
               store: store,
               list_fun: list,
               archive_fun: archive
             )
  end
end
