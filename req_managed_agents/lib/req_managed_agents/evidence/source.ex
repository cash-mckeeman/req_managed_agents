defmodule ReqManagedAgents.Evidence.Source.Interval do
  @moduledoc "The UTC bounds of a requested source interval."
  alias ReqManagedAgents.Evidence.{Error, Validation}
  @enforce_keys [:from, :to]
  defstruct [:from, :to]
  @type t :: %__MODULE__{from: DateTime.t(), to: DateTime.t()}
  @doc "Rejects invalid UTC bounds or a reversed interval."
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, fields} <-
           Validation.fields(attrs, [
             {:from, &Validation.utc/1, nil},
             {:to, &Validation.utc/1, nil}
           ]),
         true <- Validation.ordered?(fields.from, fields.to) do
      {:ok, struct!(__MODULE__, fields)}
    else
      _ -> Error.error(:invalid_input)
    end
  end
end

defmodule ReqManagedAgents.Evidence.Source do
  @moduledoc "Source-relative retrieval coverage; complete does not imply global execution visibility."
  alias ReqManagedAgents.Evidence.{Diagnostic, Error, Validation}
  alias ReqManagedAgents.Evidence.Source.Interval
  @enforce_keys [:id, :kind, :scope, :status]
  defstruct [:id, :kind, :scope, :interval, :status, :reason, pages: 0, records_seen: 0]
  @type kind :: :rma_local | :claude_session | :claude_thread | :agentcore_stream | :cloudwatch
  @type status :: :complete | :partial | :unavailable | :not_requested
  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          scope: String.t(),
          interval: Interval.t() | nil,
          status: status(),
          reason: Diagnostic.code() | nil,
          pages: non_neg_integer(),
          records_seen: non_neg_integer()
        }
  @kinds Map.new(
           ~w(rma_local claude_session claude_thread agentcore_stream cloudwatch)a,
           &{Atom.to_string(&1), &1}
         )
  @statuses Map.new(~w(complete partial unavailable not_requested)a, &{Atom.to_string(&1), &1})

  @doc "Validates identity, interval and coverage; reason is a closed diagnostic code."
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, fields} <-
           Validation.fields(attrs, [
             {:id, &Validation.id/1, nil},
             {:kind, &Validation.enum(&1, @kinds), nil},
             {:scope, &Validation.id/1, nil},
             {:status, &Validation.enum(&1, @statuses), nil},
             {:interval, &Validation.optional(&1, fn v -> Interval.new(v) end), nil},
             {:reason, &Validation.optional(&1, fn v -> Diagnostic.code(v) end), nil},
             {:pages, &Validation.nonnegative/1, 0},
             {:records_seen, &Validation.nonnegative/1, 0}
           ]) do
      {:ok, struct!(__MODULE__, fields)}
    end
  end
end
