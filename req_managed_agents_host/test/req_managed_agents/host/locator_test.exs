defmodule ReqManagedAgents.Host.LocatorTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Host.Locator
  alias ReqManagedAgents.Host.Locator.Record
  alias ReqManagedAgents.Host.Store.ETS

  setup do
    name = :"locator_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ETS.start_link(name: name)

    {:ok, store: {ETS, name: name}}
  end

  test "put/2 then fetch/2 round-trips a Record through the store", %{store: store} do
    record = Record.new("ext-1", session_id: "sess-1", agent_id: "agent-1")

    assert :ok = Locator.put(store, record)
    assert {:ok, ^record} = Locator.fetch(store, "ext-1")
  end

  test "fetch/2 of a missing id returns :error", %{store: store} do
    assert :error = Locator.fetch(store, "nonexistent")
  end

  test "mark_context_sent/2 flips context_sent to true", %{store: store} do
    record = Record.new("ext-2")
    :ok = Locator.put(store, record)

    assert :ok = Locator.mark_context_sent(store, "ext-2")
    assert {:ok, %Record{context_sent: true}} = Locator.fetch(store, "ext-2")
  end

  test "mark_context_sent/2 on a missing id returns :error", %{store: store} do
    assert :error = Locator.mark_context_sent(store, "nonexistent")
  end

  test "set_status/3 updates status", %{store: store} do
    record = Record.new("ext-3")
    :ok = Locator.put(store, record)

    assert :ok = Locator.set_status(store, "ext-3", :terminated)
    assert {:ok, %Record{status: :terminated}} = Locator.fetch(store, "ext-3")
  end

  test "set_status/3 on a missing id returns :error", %{store: store} do
    assert :error = Locator.set_status(store, "nonexistent", :terminated)
  end

  test "list_by/2 filters on a metadata subset match", %{store: store} do
    a = Record.new("ext-a", metadata: %{tenant: "acme", tier: "gold"})
    b = Record.new("ext-b", metadata: %{tenant: "acme", tier: "silver"})
    c = Record.new("ext-c", metadata: %{tenant: "globex", tier: "gold"})

    :ok = Locator.put(store, a)
    :ok = Locator.put(store, b)
    :ok = Locator.put(store, c)

    assert Locator.list_by(store, %{tenant: "acme"}) |> Enum.sort_by(& &1.external_id) == [a, b]
    assert Locator.list_by(store, %{tenant: "acme", tier: "gold"}) == [a]
  end

  test "set_status/3 :deleted drops the sibling transcript", %{store: store} do
    record = Record.new("gone")
    :ok = Locator.put(store, record)
    :ok = Locator.put_transcript(store, "gone", [%{"role" => "user", "content" => "x"}])

    assert :ok = Locator.set_status(store, "gone", :deleted)
    assert :miss = Locator.fetch_transcript(store, "gone")
  end

  test "set_status/3 :terminated does NOT touch the transcript", %{store: store} do
    record = Record.new("kept")
    :ok = Locator.put(store, record)
    :ok = Locator.put_transcript(store, "kept", [%{"role" => "user", "content" => "x"}])

    assert :ok = Locator.set_status(store, "kept", :terminated)
    assert {:ok, [_ | _]} = Locator.fetch_transcript(store, "kept")
  end

  test "list/1 ignores non-Record values that may share the store", %{store: store} do
    {mod, opts} = store
    ref = mod.ref(opts)
    record = Record.new("ext-4")

    :ok = Locator.put(store, record)
    :ok = mod.put(ref, :not_a_record, %{some: "other value"})

    assert Locator.list(store) == [record]
  end
end
