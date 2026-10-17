defmodule ReqManagedAgents.Acceptance.RecoveryAttempt do
  @moduledoc "One explicitly linked native tool use and result, bounded by provider event timestamps."
  alias ReqManagedAgents.Evidence.Validation

  @enforce_keys [
    :session_id,
    :source_id,
    :use_id,
    :result_id,
    :family,
    :target,
    :arguments,
    :started_at,
    :ended_at,
    :outcome,
    :evidence
  ]
  @derive {Inspect, except: [:arguments]}
  defstruct @enforce_keys

  @typedoc "Arguments are decoded provider-verbatim JSON at the private native edge. Times describe native events, not measured execution duration."
  @type t :: %__MODULE__{
          session_id: String.t(),
          source_id: String.t(),
          use_id: String.t(),
          result_id: String.t(),
          family: :builtin | :custom | :mcp,
          target: String.t(),
          arguments: %{String.t() => Jason.Encoder.t()},
          started_at: DateTime.t(),
          ended_at: DateTime.t(),
          outcome: :failed | :passed,
          evidence: [String.t()]
        }

  @doc "Validate native identity, explicit relationship and strictly ordered UTC event bounds."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_recovery_attempt}
  def new(attrs) when is_map(attrs) do
    identities = ~w(session_id source_id use_id result_id target)a

    with true <- Enum.sort(Map.keys(attrs)) == Enum.sort(@enforce_keys),
         true <- Enum.all?(identities, &match?({:ok, _}, Validation.id(Map.get(attrs, &1)))),
         true <- attrs.family in [:builtin, :custom, :mcp],
         true <- is_map(attrs.arguments) and Validation.json?(attrs.arguments),
         {:ok, started} <- Validation.utc(attrs.started_at),
         {:ok, ended} <- Validation.utc(attrs.ended_at),
         true <- DateTime.compare(started, ended) == :lt,
         true <- attrs.outcome in [:failed, :passed],
         true <-
           is_list(attrs.evidence) and length(attrs.evidence) == 2 and
             Enum.all?(attrs.evidence, &is_binary/1) do
      {:ok, struct!(__MODULE__, %{attrs | started_at: started, ended_at: ended})}
    else
      _ -> {:error, :invalid_recovery_attempt}
    end
  end

  def new(_), do: {:error, :invalid_recovery_attempt}
end
