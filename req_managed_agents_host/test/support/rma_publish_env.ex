defmodule ReqManagedAgents.Host.Test.RMAPublishEnv do
  @moduledoc false

  # Runs fun with RMA_PUBLISH set to value (nil unsets it), then restores the
  # previous value. Callers must be async: false: the environment is global.
  def with_value(value, fun) do
    previous = System.get_env("RMA_PUBLISH")
    put(value)

    try do
      fun.()
    after
      put(previous)
    end
  end

  defp put(nil), do: System.delete_env("RMA_PUBLISH")
  defp put(value), do: System.put_env("RMA_PUBLISH", value)
end
