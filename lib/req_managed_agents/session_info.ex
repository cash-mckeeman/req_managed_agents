defmodule ReqManagedAgents.SessionInfo do
  @moduledoc """
  Runtime identity of the session a callback is executing in — passed as the
  optional extra argument to `c:ReqManagedAgents.Handler.handle_tool_call/4`
  and `c:ReqManagedAgents.Handler.handle_event/3`.

  Grows by fields, never by arity: future runtime facts land here.
  """
  @derive Jason.Encoder
  defstruct session_id: nil, provider: nil, metadata: %{}

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          provider: module() | nil,
          metadata: map()
        }
end
