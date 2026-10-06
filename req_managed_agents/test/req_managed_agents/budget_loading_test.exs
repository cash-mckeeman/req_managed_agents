defmodule ReqManagedAgents.BudgetLoadingTest do
  @moduledoc """
  The `:budget` gate must find `supports_budget?/0` on a provider module that is not yet
  loaded: `function_exported?/3` does not load, so under lazy code loading a budgeted run in a
  fresh VM would be refused with `:budget_unsupported` unless the gate loads the module first.
  """
  # async: false — this test deletes and purges its probe module in the code server.
  use ExUnit.Case, async: false

  alias ReqManagedAgents.FakeProviders.BudgetCapable
  alias ReqManagedAgents.{Session, SessionResult}

  test "a budgeted run is accepted on a provider module that is not yet loaded" do
    assert Code.ensure_loaded?(BudgetCapable)
    :code.delete(BudgetCapable)
    :code.purge(BudgetCapable)

    refute :erlang.module_loaded(BudgetCapable)
    refute function_exported?(BudgetCapable, :supports_budget?, 0)

    assert {:ok, %SessionResult{terminal: :end_turn}} =
             Session.run(BudgetCapable,
               handler: fn _, _, _ -> {:ok, ""} end,
               turns: [],
               budget: %{max_list_cost_cents: 125},
               timeout: 2_000
             )
  end
end
