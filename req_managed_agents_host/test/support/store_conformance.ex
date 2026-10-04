defmodule ReqManagedAgents.Host.StoreConformance do
  @moduledoc """
  Shared `Store` conformance suite. `use` this in a test module whose `setup`
  puts `%{store_fixture: {module(), keyword()}}` into the test context — the
  generated tests resolve `ref = mod.ref(opts)` and exercise put/get/delete/all.
  """

  defmodule Widget do
    @moduledoc false
    defstruct [:id, :label]
  end

  defmacro __using__(_opts) do
    quote do
      test "put/2 then get/2 round-trips a struct value", %{store_fixture: {mod, opts}} do
        ref = mod.ref(opts)
        widget = %ReqManagedAgents.Host.StoreConformance.Widget{id: 1, label: "one"}

        assert :ok = mod.put(ref, :widget, widget)
        assert {:ok, ^widget} = mod.get(ref, :widget)
      end

      test "get/2 of an absent key returns :miss", %{store_fixture: {mod, opts}} do
        ref = mod.ref(opts)

        assert :miss = mod.get(ref, :nonexistent)
      end

      test "delete/2 removes the key", %{store_fixture: {mod, opts}} do
        ref = mod.ref(opts)
        widget = %ReqManagedAgents.Host.StoreConformance.Widget{id: 2, label: "two"}

        assert :ok = mod.put(ref, :widget, widget)
        assert :ok = mod.delete(ref, :widget)
        assert :miss = mod.get(ref, :widget)
      end

      test "all/1 lists every {key, value} pair that was put", %{store_fixture: {mod, opts}} do
        ref = mod.ref(opts)
        a = %ReqManagedAgents.Host.StoreConformance.Widget{id: 3, label: "a"}
        b = %ReqManagedAgents.Host.StoreConformance.Widget{id: 4, label: "b"}

        assert :ok = mod.put(ref, :a, a)
        assert :ok = mod.put(ref, :b, b)

        assert Enum.sort(mod.all(ref)) == Enum.sort([{:a, a}, {:b, b}])
      end
    end
  end
end
