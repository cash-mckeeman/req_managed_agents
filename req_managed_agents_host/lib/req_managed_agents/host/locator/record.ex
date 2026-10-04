defmodule ReqManagedAgents.Host.Locator.Record do
  @moduledoc "Durable session-locator row: external id -> upstream identity. A pointer, not an event ledger."
  @derive Jason.Encoder
  @enforce_keys [:external_id]
  defstruct external_id: nil,
            session_id: nil,
            agent_id: nil,
            environment_id: nil,
            status: :active,
            context_sent: false,
            metadata: %{}

  @type status :: :active | :terminated | :deleted
  @type t :: %__MODULE__{
          external_id: String.t(),
          session_id: String.t() | nil,
          agent_id: String.t() | nil,
          environment_id: String.t() | nil,
          status: status(),
          context_sent: boolean(),
          metadata: map()
        }

  @spec new(String.t(), keyword()) :: t()
  def new(external_id, opts \\ []) when is_binary(external_id),
    do: struct!(%__MODULE__{external_id: external_id}, opts)
end
