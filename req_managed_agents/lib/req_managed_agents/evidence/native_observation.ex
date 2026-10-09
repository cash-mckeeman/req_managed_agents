defmodule ReqManagedAgents.Evidence.NativeObservation do
  @moduledoc "Validated native facts and safe metadata; raw payloads stay on Evidence.Record."
  alias ReqManagedAgents.Evidence.{Error, Validation}
  @enforce_keys [:supported?, :malformed_metadata?, :safe_payload]
  defstruct [:native_id, :occurred_at, :supported?, :malformed_metadata?, :safe_payload]

  @type t :: %__MODULE__{
          supported?: boolean(),
          malformed_metadata?: boolean(),
          native_id: String.t() | nil,
          occurred_at: DateTime.t() | nil,
          safe_payload: map()
        }

  @doc "Rejects invalid facts or a projection that is not a JSON object."
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    with true <-
           Validation.only_keys?(attrs, [
             :supported?,
             :malformed_metadata?,
             :native_id,
             :occurred_at,
             :safe_payload
           ]),
         {:ok, fields} <-
           Validation.fields(attrs, [
             {:supported?, &boolean/1, nil},
             {:malformed_metadata?, &boolean/1, nil},
             {:native_id, &Validation.optional(&1, fn v -> Validation.id(v) end), nil},
             {:occurred_at, &Validation.optional(&1, fn v -> Validation.utc(v) end), nil},
             {:safe_payload, &projection/1, nil}
           ]) do
      {:ok, struct!(__MODULE__, fields)}
    else
      _ -> Error.error(:invalid_input)
    end
  end

  def new(_), do: Error.error(:invalid_input)

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_), do: Error.error(:invalid_input)

  defp projection(value) when is_map(value) do
    if Validation.json?(value), do: {:ok, value}, else: Error.error(:invalid_input)
  end

  defp projection(_), do: Error.error(:invalid_input)
end
