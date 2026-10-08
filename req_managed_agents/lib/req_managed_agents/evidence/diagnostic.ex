defmodule ReqManagedAgents.Evidence.Diagnostic do
  @moduledoc "Counted evidence limitations with fixed messages safe for display."
  alias ReqManagedAgents.Evidence.{Error, Validation}
  @enforce_keys [:code, :message]
  defstruct [:code, :source_id, :record_id, :message, count: 1]

  @type code ::
          :incomplete_retrieval
          | :cursor_cycle
          | :bound_exceeded
          | :source_unavailable
          | :unsupported_record
          | :conflicting_duplicate
          | :capture_gap
          | :invalid_correlation
          | :content_unavailable
          | :unresolved_operation
  @type t :: %__MODULE__{
          code: code(),
          source_id: String.t() | nil,
          record_id: String.t() | nil,
          count: non_neg_integer(),
          message: String.t()
        }
  @messages %{
    incomplete_retrieval: "Retrieval is incomplete.",
    cursor_cycle: "Retrieval repeated a cursor.",
    bound_exceeded: "A capture bound was reached.",
    source_unavailable: "The source is unavailable.",
    unsupported_record: "Some native fields or records are unsupported.",
    conflicting_duplicate: "A native identity has conflicting records.",
    capture_gap: "Some evidence could not be captured.",
    invalid_correlation: "A correlation is unavailable.",
    content_unavailable: "Record content is unavailable.",
    unresolved_operation: "An operation is unresolved."
  }
  @codes Map.new(Map.keys(@messages), &{Atom.to_string(&1), &1})

  @doc "Validates references and counts, replacing supplied text with the code's safe message."
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, fields} <-
           Validation.fields(attrs, [
             {:code, &Validation.enum(&1, @codes), nil},
             {:source_id, &Validation.optional(&1, fn v -> Validation.id(v) end), nil},
             {:record_id, &Validation.optional(&1, fn v -> Validation.id(v) end), nil},
             {:count, &Validation.nonnegative/1, 1}
           ]) do
      {:ok, struct!(__MODULE__, Map.put(fields, :message, Map.fetch!(@messages, fields.code)))}
    end
  end

  @doc false
  @spec code(term()) :: {:ok, code()} | {:error, Error.t()}
  def code(value), do: Validation.enum(value, @codes)
end
