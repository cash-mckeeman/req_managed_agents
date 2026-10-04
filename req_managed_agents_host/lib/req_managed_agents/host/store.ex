defmodule ReqManagedAgents.Host.Store do
  @moduledoc """
  Pluggable persistence for the session `Locator`. Mirrors RMA's `Provisioner.Store`
  ETS/File pattern one layer up: live-session locator rows, not provisioning digests.
  A store is referenced as `{module(), keyword()}`; `ref/1` resolves the opts to the
  concrete handle the other callbacks take.
  """
  @type store :: {module(), keyword()}
  @type ref :: term()
  @type key :: term()
  @type value :: term()

  @callback start_link(keyword()) :: {:ok, pid()} | :ignore | {:error, term()}
  @callback ref(keyword()) :: ref()
  @callback put(ref(), key(), value()) :: :ok
  @callback get(ref(), key()) :: {:ok, value()} | :miss
  @callback delete(ref(), key()) :: :ok
  @callback all(ref()) :: [{key(), value()}]
end
