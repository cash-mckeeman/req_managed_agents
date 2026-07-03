defmodule ReqManagedAgents.Artifacts do
  @moduledoc """
  One artifacts vocabulary over provider-native session storage: `list/2`,
  `fetch/3`, `put/4`, `delete/3` — name-keyed and session-scoped, because a
  file's NAME is the only identity the model can ever reference.

  A store is `{impl_module, store_term}`; build the store_term with the impl's
  constructor:

    * `ReqManagedAgents.Artifacts.ClaudeFiles.store/2` — Anthropic Files API
    * `ReqManagedAgents.Artifacts.AgentCoreSessionStorage.store/4` — AgentCore
      `sessionStorage` mount, command-backed (report-scale artifacts)

  Error normalization across impls: a missing name is `{:error, :not_found}`;
  when duplicate names exist (re-runs accumulate on CMA), `list/2` returns all
  and `fetch`/`delete` act on the newest.
  """
  alias ReqManagedAgents.Artifact

  @type store :: {module(), term()}

  @callback list(store_term :: term(), opts :: keyword()) ::
              {:ok, [Artifact.t()]} | {:error, term()}
  @callback fetch(store_term :: term(), name :: String.t(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}
  @callback put(store_term :: term(), name :: String.t(), contents :: binary(), opts :: keyword()) ::
              :ok | {:error, term()}
  @callback delete(store_term :: term(), name :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @spec list(store(), keyword()) :: {:ok, [Artifact.t()]} | {:error, term()}
  def list({impl, store}, opts \\ []), do: impl.list(store, opts)

  @spec fetch(store(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def fetch({impl, store}, name, opts \\ []), do: impl.fetch(store, name, opts)

  @spec put(store(), String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def put({impl, store}, name, contents, opts \\ []), do: impl.put(store, name, contents, opts)

  @spec delete(store(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete({impl, store}, name, opts \\ []), do: impl.delete(store, name, opts)
end
