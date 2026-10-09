defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Budget do
  @moduledoc "Claude Managed Agents budget rendering and create-response confirmation."
  alias ReqManagedAgents.Budget

  @doc """
  Render the budget as the provider's create-session `budget` field.

  The amount is a whole-cent string, which is the provider's wire form.
  """
  @spec to_wire(Budget.t()) :: map()
  def to_wire(%Budget{max_list_cost_cents: cents}) do
    %{
      type: "limit",
      max_list_cost: %{amount: Integer.to_string(cents), currency: "USD"}
    }
  end

  @doc """
  Whether a decoded provider `budget` field carries exactly this budget.

  Fields beyond the three the budget defines are ignored; a missing, `nil` or differing
  value is not confirmation.
  """
  @spec confirmed?(Budget.t(), term()) :: boolean()
  def confirmed?(%Budget{max_list_cost_cents: cents}, %{
        "type" => "limit",
        "max_list_cost" => %{"amount" => amount, "currency" => "USD"}
      }),
      do: amount == Integer.to_string(cents)

  def confirmed?(%Budget{}, _echoed), do: false
end
