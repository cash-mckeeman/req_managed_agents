defmodule ReqManagedAgents.ToolResult do
  @moduledoc "The locally-produced result of running a custom tool — what resumes the loop."
  @derive Jason.Encoder
  @enforce_keys [:tool_use_id]
  defstruct [:tool_use_id, text: "", is_error: false]

  @type t :: %__MODULE__{tool_use_id: String.t(), text: String.t(), is_error: boolean()}
end
