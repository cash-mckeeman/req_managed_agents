defmodule ReqManagedAgents.Budget do
  @moduledoc """
  A provider-enforced spending limit for a fresh Claude Managed Agents session.

  Pass it as the `:budget` option to `ReqManagedAgents.run_to_completion/1`,
  `ReqManagedAgents.start_session/1` or `ReqManagedAgents.Session.run/2`; a map with the same
  atom keys is accepted interchangeably. The cap is `max_list_cost_cents`, a positive whole
  number of US cents priced at public list rates, not at your contracted rates.

  The provider checks the running cost between model requests and pauses the session once
  it reaches the cap. The request in flight at that moment still finishes, so the final
  cost can overshoot the cap by up to one model request per thread. Size the cap with
  that margin in mind.

  A budget can only be set when the session is created. Passing `:budget` together with
  `:session_id` is an error. When a budget is requested, the session is opened only if the
  provider's create response echoes the same budget; otherwise the session is archived on a
  best-effort basis and the open fails with `{:budget_not_confirmed, echoed}`.
  """

  @enforce_keys [:max_list_cost_cents]
  defstruct [:max_list_cost_cents, type: :limit, currency: "USD"]

  @type t :: %__MODULE__{
          type: :limit,
          max_list_cost_cents: pos_integer(),
          currency: String.t()
        }

  @doc """
  Coerce a map or an existing `%Budget{}` into a validated `%Budget{}`.

  `max_list_cost_cents` must be a positive integer, `type` (default `:limit`) must be
  `:limit` and `currency` (default `"USD"`) must be `"USD"`. Anything else returns
  `{:error, :invalid_budget}`.
  """
  @spec new(t() | map()) :: {:ok, t()} | {:error, :invalid_budget}
  def new(%__MODULE__{} = budget), do: budget |> Map.from_struct() |> new()

  def new(%{max_list_cost_cents: cents} = map) when is_integer(cents) and cents > 0 do
    case {Map.get(map, :type, :limit), Map.get(map, :currency, "USD")} do
      {:limit, "USD"} -> {:ok, %__MODULE__{max_list_cost_cents: cents}}
      _ -> {:error, :invalid_budget}
    end
  end

  def new(_other), do: {:error, :invalid_budget}

  @doc """
  Render the budget as the provider's create-session `budget` field.

  The amount is a whole-cent string, which is the provider's wire form.
  """
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{max_list_cost_cents: cents}) do
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
  @spec confirmed?(t(), term()) :: boolean()
  def confirmed?(%__MODULE__{max_list_cost_cents: cents}, %{
        "type" => "limit",
        "max_list_cost" => %{"amount" => amount, "currency" => "USD"}
      }),
      do: amount == Integer.to_string(cents)

  def confirmed?(%__MODULE__{}, _echoed), do: false
end
