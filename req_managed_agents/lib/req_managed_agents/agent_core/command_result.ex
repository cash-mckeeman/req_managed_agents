defmodule ReqManagedAgents.AgentCore.CommandResult do
  @moduledoc """
  Collected output of one `InvokeAgentRuntimeCommand` execution. Not an error
  shape — callers branch on `exit_code` (0 = success; the command's own exit
  status otherwise).
  """
  @derive Jason.Encoder
  defstruct stdout: "", stderr: "", exit_code: nil

  @type t :: %__MODULE__{
          stdout: binary(),
          stderr: binary(),
          exit_code: integer() | nil
        }
end
