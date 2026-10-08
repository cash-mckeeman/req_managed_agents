defmodule ReqManagedAgents.Evidence.Error do
  @moduledoc "An evidence boundary failure with a fixed, content-free message."
  @enforce_keys [:code, :message]
  defstruct [:code, :message]

  @type code ::
          :invalid_input
          | :invalid_options
          | :invalid_reference
          | :unsupported_version
          | :bound_exceeded
          | :recorder_unavailable
          | :artifact_write_failed
  @type t :: %__MODULE__{code: code(), message: String.t()}

  @messages %{
    invalid_input: "Invalid evidence input.",
    recorder_unavailable: "Evidence recorder is unavailable.",
    invalid_options: "Invalid capture options.",
    invalid_reference: "Invalid evidence reference.",
    unsupported_version: "Unsupported evidence version.",
    bound_exceeded: "Capture metadata exceeds the byte bound.",
    artifact_write_failed: "Evidence artifact could not be published."
  }
  @codes Map.new(Map.keys(@messages), &{Atom.to_string(&1), &1})

  @doc "Validates the code; caller-supplied messages are never retained."
  @spec new(map()) :: {:ok, t()} | {:error, t()}
  def new(attrs) when is_map(attrs) do
    code = Map.get(attrs, :code, Map.get(attrs, "code"))
    code = if is_binary(code), do: Map.get(@codes, code), else: code

    case Map.fetch(@messages, code) do
      {:ok, message} -> {:ok, %__MODULE__{code: code, message: message}}
      :error -> error(:invalid_input)
    end
  end

  def new(_), do: error(:invalid_input)

  @doc false
  @spec error(code()) :: {:error, t()}
  def error(code), do: {:error, %__MODULE__{code: code, message: Map.fetch!(@messages, code)}}
end
