defmodule ReqManagedAgents.Provisioner.Name.Policy do
  @moduledoc """
  Per-provider naming constraints for `ReqManagedAgents.Provisioner.Name`.

  `max_length` and `charset` differ sharply between providers: AgentCore's
  `harnessName` is capped at 40 characters over `[a-zA-Z][a-zA-Z0-9_]`, while the
  Claude Managed Agents agent `name` allows 256 with no documented charset
  restriction. Parameterising both keeps one fit-and-fallback implementation
  without pushing AWS's charset onto names that never needed it — forcing
  `[a-zA-Z0-9_]` onto CMA would rewrite every hyphenated agent name and rotate
  resources for no benefit.

  The two constructors below are the only supported policies; there is
  deliberately no public `new/1`, so `max_length` is always large enough to hold
  a digest plus the truncation hash.
  """

  @enforce_keys [:max_length, :charset, :leading]
  defstruct [:max_length, :charset, :leading]

  @type charset :: :alnum_underscore | :permissive
  @type leading :: :alpha | :any
  @type t :: %__MODULE__{
          max_length: pos_integer(),
          charset: charset(),
          leading: leading()
        }

  @doc "The Bedrock AgentCore `harnessName` policy: `[a-zA-Z][a-zA-Z0-9_]{0,39}`."
  @spec agent_core() :: t()
  def agent_core, do: %__MODULE__{max_length: 40, charset: :alnum_underscore, leading: :alpha}

  @doc "The Claude Managed Agents agent `name` policy: 256 characters, unrestricted charset."
  @spec claude_managed_agents() :: t()
  def claude_managed_agents,
    do: %__MODULE__{max_length: 256, charset: :permissive, leading: :any}
end
