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
    case fetch_layer(opts, key, env_var) do
      {:ok, val} -> val
      :error -> default
    end
  end

  @spec resolve!(keyword(), atom(), String.t()) :: term()
  def resolve!(opts, key, env_var) do
    case fetch_layer(opts, key, env_var) do
      {:ok, val} ->
        val

      :error ->
        raise "missing required configuration: set opt #{inspect(key)}, " <>
                "config #{inspect(@app)}, #{inspect(key)}, or env #{env_var}"
    end
  end

  # First layer that HAS the key wins — even if its value is nil/false.
  defp fetch_layer(opts, key, env_var) do
    with :error <- Keyword.fetch(opts, key),
         :error <- Application.fetch_env(@app, key) do
      fetch_env(env_var)
    end
  end

  defp fetch_env(nil), do: :error
  defp fetch_env(var), do: System.fetch_env(var)
end
