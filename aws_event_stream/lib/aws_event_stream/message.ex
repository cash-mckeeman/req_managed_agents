defmodule AWSEventStream.Message do
  @moduledoc "A decoded AWS event-stream message: ordered headers + opaque payload bytes."
  alias AWSEventStream.Header

  @type t :: %__MODULE__{headers: [Header.t()], payload: binary()}
  defstruct headers: [], payload: <<>>

  @doc "Value of the first header named `name`, or nil."
  @spec header(t(), String.t()) :: term() | nil
  def header(%__MODULE__{headers: headers}, name) do
    Enum.find_value(headers, fn
      %Header{name: ^name, value: value} -> {:ok, value}
      _ -> nil
    end)
    |> case do
      {:ok, value} -> value
      nil -> nil
    end
  end
end
