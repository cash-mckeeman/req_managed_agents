defmodule ReqManagedAgents.ToolUse do
  @moduledoc "A tool call — client-side (custom, return-of-control) or server-side (observe-only)."
  @derive Jason.Encoder
  @enforce_keys [:name]
  defstruct [:id, :name, input: %{}]

  @type t :: %__MODULE__{id: String.t() | nil, name: String.t(), input: map()}
end
