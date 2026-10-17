defmodule ReqManagedAgents.Acceptance.Cleanup.Resource do
  @moduledoc false
  @enforce_keys [:kind, :reference]
  defstruct @enforce_keys
  @type t :: %__MODULE__{kind: :claude_session, reference: String.t()}
end

defmodule ReqManagedAgents.Acceptance.Cleanup do
  @moduledoc "Exact newly created session ownership for external infrastructure cleanup."
  alias ReqManagedAgents.Acceptance.Cleanup.Resource
  alias ReqManagedAgents.Acceptance.Config
  alias ReqManagedAgents.Evidence.{Capture, Validation}
  @enforce_keys [:status, :owned_resources]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          status: :not_owned | :pending | :unknown | :complete,
          owned_resources: [Resource.t()]
        }

  @doc "Selected agents, environments and harnesses are never owned by acceptance."
  @spec new(Config.t(), Capture.t() | nil) :: {:ok, t()}
  def new(%Config{provider: :agentcore}, _),
    do: {:ok, %__MODULE__{status: :not_owned, owned_resources: []}}

  def new(%Config{provider: :claude_managed_agents}, %Capture{session_id: id}) when is_binary(id),
    do:
      {:ok,
       %__MODULE__{
         status: :pending,
         owned_resources: [%Resource{kind: :claude_session, reference: id}]
       }}

  def new(_, _), do: {:ok, %__MODULE__{status: :unknown, owned_resources: []}}

  @doc "Preserve exact validated session ownership and its observed archive outcome."
  @spec owned_session(term(), term()) :: {:ok, t()} | {:error, :invalid_cleanup}
  def owned_session(id, status) when status in [:complete, :pending, :unknown] do
    case Validation.safe_id(id) do
      {:ok, id} ->
        {:ok,
         %__MODULE__{
           status: status,
           owned_resources: [%Resource{kind: :claude_session, reference: id}]
         }}

      _ ->
        {:error, :invalid_cleanup}
    end
  end

  def owned_session(_, _), do: {:error, :invalid_cleanup}

  @doc false
  @spec from_observations(Config.t(), Capture.t() | nil, [
          ReqManagedAgents.Acceptance.Observation.t()
        ]) :: {:ok, t()}
  def from_observations(config, capture, observations) do
    case Enum.find(observations, &match?(%__MODULE__{}, &1.cleanup)) do
      nil -> new(config, capture)
      observation -> {:ok, observation.cleanup}
    end
  end

  @doc "Render cleanup instructions without asserting cleanup has already occurred."
  @spec to_wire(t()) :: %{String.t() => Jason.Encoder.t()}
  def to_wire(cleanup),
    do: %{
      "status" => Atom.to_string(cleanup.status),
      "owned_resources" =>
        Enum.map(
          cleanup.owned_resources,
          &%{"kind" => Atom.to_string(&1.kind), "reference" => &1.reference}
        )
    }
end
