defmodule ReqManagedAgents.Acceptance.Observation do
  @moduledoc "A bounded source-qualified execution observation; native content stays in evidence."
  @enforce_keys [:name, :outcome, :references]
  defstruct @enforce_keys ++ [capture: nil]

  @type t :: %__MODULE__{
          name: String.t(),
          outcome: :passed | :failed | :inconclusive,
          references: [String.t()],
          capture: ReqManagedAgents.Evidence.Capture.t() | nil
        }

  @doc "Construct an observation without exposing provider failure bodies."
  @spec new(String.t(), :passed | :failed | :inconclusive, [String.t()]) ::
          {:ok, t()} | {:error, :invalid_observation}
  def new(name, outcome, references) when is_binary(name) and is_list(references) do
    if name != "" and outcome in [:passed, :failed, :inconclusive] and
         Enum.all?(references, &is_binary/1),
       do: {:ok, %__MODULE__{name: name, outcome: outcome, references: references}},
       else: {:error, :invalid_observation}
  end

  def new(_, _, _), do: {:error, :invalid_observation}
end
