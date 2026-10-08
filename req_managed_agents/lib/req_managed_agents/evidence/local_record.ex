defmodule ReqManagedAgents.Evidence.LocalRecord do
  @moduledoc "Local lifecycle input, mapped explicitly to the versioned evidence payload."
  alias ReqManagedAgents.Evidence.{Error, Validation}
  alias ReqManagedAgents.Evidence.Record.Payload

  @enforce_keys [:payload]
  defstruct [:payload]
  @type t :: %__MODULE__{payload: Payload.t()}
  @types %{
    invocation_start: :invocation_started,
    invocation_end: :invocation_finished,
    attempt_start: :attempt_started,
    attempt_end: :attempt_finished,
    retry: :retry_decided,
    transport_error: :transport_failed,
    tool_start: :tool_started,
    tool_end: :tool_finished
  }

  @doc "Validates lifecycle fields; error codes must be content-free identifiers."
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, type} <- Map.fetch(@types, Validation.get(attrs, :type)),
         attrs = attrs |> Map.delete("type") |> Map.put(:type, type),
         {:ok, payload} <- Payload.new(attrs) do
      {:ok, %__MODULE__{payload: payload}}
    else
      _ -> Error.error(:invalid_input)
    end
  end

  def new(_), do: Error.error(:invalid_input)
end
