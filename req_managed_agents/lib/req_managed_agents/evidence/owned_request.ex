defmodule ReqManagedAgents.Evidence.OwnedRequest do
  @moduledoc false

  @spec run((-> term()), integer()) :: {:ok, term()} | {:error, :deadline | :request_failed}
  def run(fun, deadline) when is_function(fun, 0) and is_integer(deadline) do
    owner = self()
    token = make_ref()
    callers = [owner | Process.get(:"$callers", [])]
    {guard, monitor} = spawn_monitor(fn -> guard(owner, token, callers, fun, deadline) end)

    receive do
      {^token, result} ->
        receive do
          {:DOWN, ^monitor, :process, ^guard, _} -> result
        end

      {:DOWN, ^monitor, :process, ^guard, _} ->
        {:error, :request_failed}
    end
  end

  defp guard(owner, token, callers, fun, deadline) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(owner)
    guard = self()
    worker_token = make_ref()

    {worker, worker_monitor} =
      :erlang.spawn_opt(
        fn ->
          Process.put(:"$callers", callers)
          send(guard, {worker_token, fun.()})
        end,
        [:link, :monitor]
      )

    receive do
      {^worker_token, result} ->
        reap(worker, worker_monitor)
        send(owner, {token, {:ok, result}})

      {:DOWN, ^worker_monitor, :process, ^worker, _} ->
        send(owner, {token, {:error, :request_failed}})

      {:DOWN, ^owner_monitor, :process, ^owner, _} ->
        reap(worker, worker_monitor)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        reap(worker, worker_monitor)
        send(owner, {token, {:error, :deadline}})
    end
  end

  defp reap(worker, monitor) do
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _} -> :ok
    end
  end
end
