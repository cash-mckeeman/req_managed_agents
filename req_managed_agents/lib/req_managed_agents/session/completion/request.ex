defmodule ReqManagedAgents.Session.Completion.Request do
  @moduledoc false
  alias ReqManagedAgents.SessionResult
  @enforce_keys [:owner, :generation, :snapshot]
  defstruct @enforce_keys ++ [pending_messages: []]

  @type t :: %__MODULE__{
          owner: pid(),
          generation: reference() | nil,
          snapshot: SessionResult.t(),
          pending_messages: [String.t()]
        }

  @spec new(pid(), reference(), SessionResult.t(), keyword()) :: t()
  def new(owner, generation, %SessionResult{} = snapshot, opts \\ [])
      when is_pid(owner) and is_reference(generation),
      do: %__MODULE__{
        owner: owner,
        generation: generation,
        snapshot: snapshot,
        pending_messages: Keyword.get(opts, :pending_messages, [])
      }
end
