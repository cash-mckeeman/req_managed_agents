defmodule ReqManagedAgents.Host.Config do
  @moduledoc "Resolved, validated host configuration. The struct threaded through the host; not raw opts."
  @enforce_keys [:provider, :handler, :store]
  defstruct provider: nil,
            provider_opts: [],
            handler: nil,
            store: nil,
            agent: nil,
            environment: nil,
            metadata: %{},
            idle_timeout_ms: 300_000,
            timeout_ms: 600_000

  @type store :: {module(), keyword()}
  @type t :: %__MODULE__{
          provider: module(),
          provider_opts: keyword(),
          handler: module(),
          store: store(),
          agent: ReqManagedAgents.Agent.Handle.t() | nil,
          environment: ReqManagedAgents.Provisioner.Environment.Handle.t() | nil,
          metadata: map(),
          idle_timeout_ms: non_neg_integer(),
          timeout_ms: non_neg_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, {:invalid_config, atom()}}
  def new(opts) do
    with {:ok, provider} <- fetch(opts, :provider),
         {:ok, handler} <- fetch(opts, :handler),
         {:ok, store} <- fetch(opts, :store) do
      {:ok,
       struct!(
         %__MODULE__{provider: provider, handler: handler, store: store},
         Keyword.drop(opts, [:provider, :handler, :store])
       )}
    end
  end

  defp fetch(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, v} when not is_nil(v) -> {:ok, v}
      _ -> {:error, {:invalid_config, key}}
    end
  end
end
