defmodule ReqManagedAgents.BudgetTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Budget

  describe "new/1" do
    test "stores only the cap; the type and currency the provider fixes are not fields" do
      assert {:ok, %Budget{max_list_cost_cents: 125} = budget} =
               Budget.new(%{max_list_cost_cents: 125, type: :limit, currency: "USD"})

      assert budget |> Map.from_struct() |> Map.keys() == [:max_list_cost_cents]
    end

    test "accepts an existing struct" do
      {:ok, budget} = Budget.new(%{max_list_cost_cents: 50})
      assert {:ok, ^budget} = Budget.new(budget)
    end

    test "rejects a struct whose fields were altered after construction" do
      {:ok, budget} = Budget.new(%{max_list_cost_cents: 50})
      assert {:error, :invalid_budget} = Budget.new(%{budget | max_list_cost_cents: 0})
    end

    test "rejects non-positive and non-integer amounts" do
      for cents <- [0, -1, 1.0, "5", nil] do
        assert {:error, :invalid_budget} = Budget.new(%{max_list_cost_cents: cents})
      end
    end
  end

  test "to_wire/1 renders the amount as a whole-cent string" do
    {:ok, budget} = Budget.new(%{max_list_cost_cents: 5})

    assert Budget.to_wire(budget) ==
             %{type: "limit", max_list_cost: %{amount: "5", currency: "USD"}}
  end

  describe "confirmed?/2" do
    setup do
      {:ok, budget} = Budget.new(%{max_list_cost_cents: 125})
      {:ok, budget: budget}
    end

    test "true for the same budget, ignoring extra fields", %{budget: budget} do
      echo = %{
        "type" => "limit",
        "max_list_cost" => %{"amount" => "125", "currency" => "USD"},
        "extra" => 1
      }

      assert Budget.confirmed?(budget, echo)
    end

    test "false for nil, a different amount or a different currency", %{budget: budget} do
      limit = fn amount, currency ->
        %{"type" => "limit", "max_list_cost" => %{"amount" => amount, "currency" => currency}}
      end

      refute Budget.confirmed?(budget, nil)
      refute Budget.confirmed?(budget, limit.("124", "USD"))
      refute Budget.confirmed?(budget, limit.("125", "EUR"))
      refute Budget.confirmed?(budget, Map.put(limit.("125", "USD"), "type", "other"))
      refute Budget.confirmed?(budget, limit.(125, "USD"))
    end
  end
end
