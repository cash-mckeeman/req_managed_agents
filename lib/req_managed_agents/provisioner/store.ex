defmodule ReqManagedAgents.Provisioner.Store do
  @moduledoc """
  Storage behaviour for the provision cache: where `{spec-hash → handle}` and
  tag pointers live. `ReqManagedAgents.Provisioner.Store.ETS` (default) keeps
  today's in-process semantics; `ReqManagedAgents.Provisioner.Store.File`
  persists across OS processes for CLI/mix-task/cron consumers.

  Keys are namespaced strings (`"provision:" <> hash`, `"tag:" <> base <> ":" <> tag`).
  `delete_value/2` exists because eviction is value-keyed (a teardown holds the
  handle, not the key).
  """
  @callback get(store_opts :: term(), key :: String.t()) :: {:ok, term()} | :miss
  @callback put(store_opts :: term(), key :: String.t(), value :: term()) :: :ok
  @callback delete(store_opts :: term(), key :: String.t()) :: :ok
  @callback delete_value(store_opts :: term(), value :: term()) :: :ok
end
