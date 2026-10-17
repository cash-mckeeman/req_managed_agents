defmodule ReqManagedAgents.Acceptance.Assertion do
  @moduledoc "A named acceptance predicate and its source-qualified evidence references."
  @enforce_keys [:name, :outcome, :evidence]
  defstruct @enforce_keys
  @type outcome :: :passed | :failed | :unsupported | :inconclusive
  @type t :: %__MODULE__{name: String.t(), outcome: outcome(), evidence: [String.t()]}

  @doc "Passing predicates require at least one evidence reference."
  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, :invalid_assertion}
  def new(name, outcome, evidence) when is_binary(name) and is_list(evidence) do
    if name != "" and outcome in [:passed, :failed, :unsupported, :inconclusive] and
         Enum.all?(evidence, &(is_binary(&1) and &1 != "")) and
         (outcome != :passed or evidence != []) do
      {:ok, %__MODULE__{name: name, outcome: outcome, evidence: evidence}}
    else
      {:error, :invalid_assertion}
    end
  end

  def new(_, _, _), do: {:error, :invalid_assertion}

  @doc "Render one predicate without provider payloads."
  @spec to_wire(t()) :: %{String.t() => Jason.Encoder.t()}
  def to_wire(%__MODULE__{} = assertion) do
    %{
      "name" => assertion.name,
      "outcome" => Atom.to_string(assertion.outcome),
      "evidence" => assertion.evidence
    }
  end
end
