defmodule ReqManagedAgents.TeardownLoadingTest do
  @moduledoc """
  `ReqManagedAgents.teardown/3` must find a provider's `teardown/2` even when the
  provider module is not yet loaded (`function_exported?/3` does not load — under
  interactive-mode lazy loading, a teardown-first call pattern in a fresh VM would
  silently report `{:error, :not_supported}` and leak the provisioned resource).
  """
  # async: false — this test manipulates code-server state (delete/purge) for its
  # dedicated probe module.
  use ExUnit.Case, async: false

  alias ReqManagedAgents.FakeProviders.TeardownProbe

  test "teardown/3 reaches teardown/2 on a not-yet-loaded provider module" do
    # Start loaded (sanity), then unload: delete makes current code old, purge drops it.
    assert Code.ensure_loaded?(TeardownProbe)
    :code.delete(TeardownProbe)
    :code.purge(TeardownProbe)

    # The misfire the fix prevents: with the module unloaded, a bare
    # function_exported?/3 reads "not implemented".
    refute :erlang.module_loaded(TeardownProbe)
    refute function_exported?(TeardownProbe, :teardown, 2)

    # The facade must still find and invoke the real teardown/2 (its {:error, :probe}
    # return also proves we did NOT take the {:error, :not_supported} branch).
    assert {:error, :probe} = ReqManagedAgents.teardown(TeardownProbe, %{}, [])
  end
end
