defmodule ReqManagedAgents.Session.Completion do
  @moduledoc false
  use GenServer
  alias ReqManagedAgents.Session.Completion.State
  alias ReqManagedAgents.SessionResult

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts), do: GenServer.start(__MODULE__, opts)

  @spec register_session(pid(), pid()) :: :ok | {:error, :closed}
  def register_session(owner, session), do: call(owner, {:session, session})

  @spec register_worker(pid(), pid()) :: :ok | {:error, :closed}
  def register_worker(owner, worker) do
    case call(owner, {:worker, worker}) do
      :ok ->
        :ok

      {:error, :closed} = error ->
        reap([{worker, Process.monitor(worker)}])
        error
    end
  end

  @spec arm_timeout(pid(), non_neg_integer() | :infinity) :: :ok | {:error, :closed}
  def arm_timeout(owner, timeout), do: call(owner, {:timeout, timeout})

  @spec begin_request(pid(), reference(), SessionResult.t()) :: :ok | {:error, :closed}
  def begin_request(owner, generation, snapshot), do: call(owner, {:begin, generation, snapshot})

  @spec checkpoint(pid(), reference(), SessionResult.t()) :: :ok | {:error, :closed}
  def checkpoint(owner, generation, snapshot),
    do: call(owner, {:checkpoint, generation, snapshot})

  @spec finish(pid(), reference(), {:ok, SessionResult.t()} | {:error, term()}, SessionResult.t()) ::
          :ok | {:error, :closed}
  def finish(owner, generation, result, snapshot),
    do: call(owner, {:finish, generation, result, snapshot})

  @spec abort(pid(), term()) :: :ok
  def abort(owner, reason) do
    call(owner, {:abort, reason})
    :ok
  end

  defp call(owner, request) do
    GenServer.call(owner, request, :infinity)
  catch
    :exit, _reason -> {:error, :closed}
  end

  @impl true
  def init(opts) do
    caller = Keyword.fetch!(opts, :caller)

    state = %State{
      caller: caller,
      caller_monitor: Process.monitor(caller),
      reply_to: Keyword.get(opts, :reply_to, caller),
      notify: opts[:notify]
    }

    {:ok, if(opts[:deadline], do: arm(state, opts[:deadline]), else: state)}
  end

  @impl true
  def handle_call(request, from, state) do
    if expired?(state) do
      state = close(state, :timeout)
      {:stop, :normal, {:error, :closed}, state}
    else
      dispatch(request, from, state)
    end
  end

  defp dispatch({:session, pid}, _from, %State{session: nil} = state),
    do: {:reply, :ok, %{state | session: {pid, Process.monitor(pid)}}}

  defp dispatch({:worker, pid}, _from, state) do
    workers = Map.put_new_lazy(state.workers, pid, fn -> Process.monitor(pid) end)
    {:reply, :ok, %{state | workers: workers}}
  end

  defp dispatch({:timeout, _timeout}, _from, %State{completed?: true} = state),
    do: {:reply, :ok, state}

  defp dispatch({:timeout, :infinity}, _from, state), do: {:reply, :ok, state}

  defp dispatch({:timeout, timeout}, _from, state) do
    deadline = now() + timeout
    deadline = if state.deadline, do: min(deadline, state.deadline), else: deadline
    {:reply, :ok, arm(state, deadline)}
  end

  defp dispatch(
         {:begin, generation, %SessionResult{} = snapshot},
         _from,
         %State{generation: nil} = state
       )
       when is_reference(generation) do
    state = %{state | generation: generation, snapshot: snapshot, completed?: false}
    state = if state.deadline && is_nil(state.timer), do: arm(state, state.deadline), else: state
    {:reply, :ok, state}
  end

  defp dispatch(
         {:checkpoint, generation, %SessionResult{} = snapshot},
         _from,
         %State{generation: generation} = state
       )
       when is_reference(generation),
       do: {:reply, :ok, %{state | snapshot: snapshot}}

  defp dispatch(
         {:finish, generation, result, %SessionResult{} = snapshot},
         _from,
         %State{generation: generation} = state
       )
       when is_reference(generation) do
    state = publish(%{state | snapshot: snapshot}, result)
    {:reply, :ok, cancel_timer(state)}
  end

  defp dispatch({:abort, reason}, _from, state),
    do: {:stop, :normal, :ok, close(state, reason)}

  defp dispatch(_request, _from, state), do: {:reply, {:error, :closed}, state}

  @impl true
  def handle_info({:expire, token}, %State{timer_token: token} = state),
    do: {:stop, :normal, close(state, :timeout)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{caller_monitor: ref} = state),
    do: {:stop, :normal, close(state, reason)}

  def handle_info({:DOWN, ref, :process, pid, reason}, %State{session: {pid, ref}} = state) do
    reason = if expired?(state), do: :timeout, else: reason
    {:stop, :normal, close(%{state | session: nil}, reason)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | workers: Map.delete(state.workers, pid)}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  defdelegate format_status(status), to: ReqManagedAgents.Session

  defp close(state, reason) do
    state = if state.completed?, do: state, else: publish(state, {:error, reason})
    cleanup(state)
  end

  defp publish(%State{} = state, result) do
    if state.snapshot && is_pid(state.notify) do
      snapshot =
        case result do
          {:ok, snapshot} -> snapshot
          {:error, _} -> %{state.snapshot | terminal: :terminated}
        end

      send(state.notify, {:managed_agents_session, snapshot})
    end

    if is_pid(state.reply_to), do: send(state.reply_to, {:session_completion, self(), result})
    %{state | generation: nil, completed?: true}
  end

  defp cleanup(state) do
    owned = Map.to_list(state.workers)
    owned = if state.session, do: [state.session | owned], else: owned
    reap(owned)
    cancel_timer(state)
  end

  defp reap(owned) do
    Enum.each(owned, fn {pid, _ref} -> Process.exit(pid, :kill) end)

    Enum.each(owned, fn {pid, ref} ->
      receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
    end)
  end

  defp arm(state, deadline) do
    state = cancel_timer(state)
    token = make_ref()
    timer = Process.send_after(self(), {:expire, token}, max(0, deadline - now()))
    %{state | timer: timer, timer_token: token, deadline: deadline}
  end

  defp cancel_timer(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: nil, timer_token: nil}
  end

  defp expired?(%State{deadline: nil}), do: false
  defp expired?(state), do: now() >= state.deadline
  defp now, do: System.monotonic_time(:millisecond)
end
