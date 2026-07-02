defmodule ReqManagedAgents.ProvisioningTest do
  use ExUnit.Case, async: false
  alias ReqManagedAgents.Provisioner

  defmodule FakeProvider do
    def provision(spec, opts), do: opts[:create_fun].(spec)

    def teardown(handle, opts) do
      case (opts[:delete_fun] || fn _ -> {:ok, %{}} end).(handle) do
        {:ok, _} -> :ok
        err -> err
      end
    end
  end

  defmodule NoTeardownProvider do
    def provision(spec, opts), do: opts[:create_fun].(spec)
  end

  @spec_a %{system_prompt: "s", tools: [], terminal_tool: nil, model_config: "m"}

  setup do
    Provisioner.reset()
    :ok
  end

  test "ensure/3 provisions on miss and serves cache on hit (provision called once)" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    create = fn _ ->
      Agent.update(counter, &(&1 + 1))
      {:ok, %{id: "h1"}}
    end

    assert {:ok, %{id: "h1"}} = Provisioner.ensure(FakeProvider, @spec_a, create_fun: create)
    assert {:ok, %{id: "h1"}} = Provisioner.ensure(FakeProvider, @spec_a, create_fun: create)
    assert Agent.get(counter, & &1) == 1
  end

  test "ensure/3 is keyed by {provider, spec}: same spec on two providers → two handles" do
    assert {:ok, %{id: "a"}} =
             Provisioner.ensure(FakeProvider, @spec_a, create_fun: fn _ -> {:ok, %{id: "a"}} end)

    assert {:ok, %{id: "b"}} =
             Provisioner.ensure(NoTeardownProvider, @spec_a,
               create_fun: fn _ -> {:ok, %{id: "b"}} end
             )
  end

  test "ensure/3 wraps a provision error and does not cache it" do
    assert {:error, {:provision_failed, :boom}} =
             Provisioner.ensure(FakeProvider, @spec_a, create_fun: fn _ -> {:error, :boom} end)

    assert {:ok, %{id: "ok"}} =
             Provisioner.ensure(FakeProvider, @spec_a, create_fun: fn _ -> {:ok, %{id: "ok"}} end)
  end

  test "ReqManagedAgents.provision/3 delegates to the cache" do
    assert {:ok, %{id: "h"}} =
             ReqManagedAgents.provision(FakeProvider, @spec_a,
               create_fun: fn _ -> {:ok, %{id: "h"}} end
             )
  end

  test "teardown/3 tears down + evicts; provider without teardown → {:error, :not_supported}" do
    {:ok, torn} = Agent.start_link(fn -> [] end)

    {:ok, %{id: "h"}} =
      Provisioner.ensure(FakeProvider, @spec_a, create_fun: fn _ -> {:ok, %{id: "h"}} end)

    delete = fn h ->
      Agent.update(torn, &[h.id | &1])
      {:ok, %{}}
    end

    assert :ok = ReqManagedAgents.teardown(FakeProvider, %{id: "h"}, delete_fun: delete)
    assert Agent.get(torn, & &1) == ["h"]

    # evicted: a subsequent ensure re-provisions
    {:ok, c} = Agent.start_link(fn -> 0 end)

    assert {:ok, %{id: "h2"}} =
             Provisioner.ensure(FakeProvider, @spec_a,
               create_fun: fn _ ->
                 Agent.update(c, &(&1 + 1))
                 {:ok, %{id: "h2"}}
               end
             )

    assert Agent.get(c, & &1) == 1

    assert {:error, :not_supported} = ReqManagedAgents.teardown(NoTeardownProvider, %{id: "x"})
  end

  test "teardown/3 does NOT evict when the provider teardown fails" do
    {:ok, c} = Agent.start_link(fn -> 0 end)

    create = fn _ ->
      Agent.update(c, &(&1 + 1))
      {:ok, %{id: "h"}}
    end

    {:ok, %{id: "h"}} = Provisioner.ensure(FakeProvider, @spec_a, create_fun: create)

    assert {:error, :nope} =
             ReqManagedAgents.teardown(FakeProvider, %{id: "h"},
               delete_fun: fn _ -> {:error, :nope} end
             )

    # still cached: ensure/3 serves the cached handle, create_fun NOT called again
    assert {:ok, %{id: "h"}} = Provisioner.ensure(FakeProvider, @spec_a, create_fun: create)
    assert Agent.get(c, & &1) == 1
  end
end
