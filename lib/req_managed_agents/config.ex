defmodule ReqManagedAgents.Config do
  @moduledoc """
  The single resolution point for library configuration. Every value follows
  the same priority: an explicit `opts` keyword, then
  `Application.get_env(:req_managed_agents, key)`, then a `System.get_env`
  environment variable, then a default. Callers never read env directly — so
  the whole config surface is one grep for `Config.resolve` away.
  """
  @app :req_managed_agents

  @spec resolve(keyword(), atom(), String.t() | nil, term()) :: term()
  def resolve(opts, key, env_var \\ nil, default \\ nil) do
    opts[key] || Application.get_env(@app, key) || env(env_var) || default
  end

  @spec resolve!(keyword(), atom(), String.t()) :: term()
  def resolve!(opts, key, env_var) do
    resolve(opts, key, env_var) ||
      raise "missing required configuration: set opt #{inspect(key)}, " <>
              "config #{inspect(@app)}, #{inspect(key)}, or env #{env_var}"
  end

  defp env(nil), do: nil
  defp env(var), do: System.get_env(var)
end
