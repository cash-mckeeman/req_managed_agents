defmodule ReqManagedAgents.Session.Completion.State do
  @moduledoc false
  @enforce_keys [:caller, :caller_monitor, :reply_to]
  defstruct [
    :caller,
    :caller_monitor,
    :reply_to,
    :notify,
    :session,
    :generation,
    :snapshot,
    :timer,
    :timer_token,
    :deadline,
    completed?: false,
    workers: %{}
  ]

  @type t :: %__MODULE__{
          caller: pid(),
          caller_monitor: reference(),
          reply_to: pid() | nil,
          notify: pid() | nil,
          session: {pid(), reference()} | nil,
          generation: reference() | nil,
          snapshot: ReqManagedAgents.SessionResult.t() | nil,
          timer: reference() | nil,
          timer_token: reference() | nil,
          deadline: integer() | nil,
          completed?: boolean(),
          workers: %{pid() => reference()}
        }
end
