defmodule ReqManagedAgents.Session.CompletionTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Session.Completion
  alias ReqManagedAgents.{SessionResult, Usage}

  test "session death publishes the acknowledged snapshot before completion and reaps workers" do
    owner = owner()
    session = actor()
    worker = actor()
    worker_ref = Process.monitor(worker)
    owner_ref = Process.monitor(owner)
    generation = make_ref()
    assert :ok = Completion.register_session(owner, session)
    assert :ok = Completion.register_worker(owner, worker)
    assert :ok = Completion.begin_request(owner, generation, snapshot(0))
    assert :ok = Completion.checkpoint(owner, generation, snapshot(1))
    Process.exit(session, :kill)
    assert {:notify, result} = delivery(owner)
    assert result.terminal == :terminated
    assert result.turns == 1
    assert result.usage.input_tokens == 12
    assert result.usage.output_tokens == 4
    assert result.usage.cache_read_input_tokens == 3
    assert result.usage.cache_creation_input_tokens == 2
    assert result.stop_reason == %{"type" => "native-stop"}
    assert result.in_flight == :unknown
    assert_receive {:session_completion, ^owner, {:error, :killed}}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    refute_receive {:managed_agents_session, _}
  end

  test "success and repeated finish or abort cannot publish the same generation twice" do
    owner = owner()
    session = actor()
    assert :ok = Completion.register_session(owner, session)
    generation = make_ref()
    result = Map.put(snapshot(1), :in_flight, :none)
    assert :ok = Completion.begin_request(owner, generation, snapshot(0))
    assert :ok = Completion.finish(owner, generation, {:ok, result}, result)
    assert_receive {:managed_agents_session, ^result}
    assert_receive {:session_completion, ^owner, {:ok, ^result}}
    assert {:error, :closed} = Completion.finish(owner, generation, {:ok, result}, result)
    assert :ok = Completion.abort(owner, :timeout)
    refute_receive {:managed_agents_session, _}
    refute_receive {:session_completion, ^owner, _}
  end

  test "abort wins over late success and late worker registration reaps that worker" do
    owner = owner()
    generation = make_ref()
    assert :ok = Completion.begin_request(owner, generation, snapshot(1))
    assert :ok = Completion.abort(owner, :timeout)
    assert_receive {:managed_agents_session, result}
    assert result.terminal == :terminated
    assert_receive {:session_completion, ^owner, {:error, :timeout}}
    assert {:error, :closed} = Completion.finish(owner, generation, {:ok, result}, result)
    worker = actor()
    ref = Process.monitor(worker)
    assert {:error, :closed} = Completion.register_worker(owner, worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    refute_receive {:managed_agents_session, _}
  end

  test "a new generation resets snapshots even with the same remote session id" do
    owner = owner()
    first = make_ref()
    second = make_ref()
    result = snapshot(1)
    assert :ok = Completion.begin_request(owner, first, result)
    assert :ok = Completion.finish(owner, first, {:ok, result}, result)
    assert_receive {:managed_agents_session, ^result}
    assert_receive {:session_completion, ^owner, {:ok, ^result}}
    assert :ok = Completion.begin_request(owner, second, snapshot(0))
    assert {:error, :closed} = Completion.checkpoint(owner, first, result)
    assert :ok = Completion.abort(owner, :timeout)
    assert_receive {:managed_agents_session, fresh}
    assert fresh.session_id == "same-session"
    assert fresh.turns == 0
    assert fresh.usage == Usage.zero()
    assert_receive {:session_completion, ^owner, {:error, :timeout}}
    refute_receive {:managed_agents_session, _}
  end

  test "death before acknowledged open has no fabricated result" do
    owner = owner()
    session = actor()
    assert :ok = Completion.register_session(owner, session)
    Process.exit(session, :kill)
    assert_receive {:session_completion, ^owner, {:error, :killed}}
    refute_receive {:managed_agents_session, _}
  end

  test "stopping an idle live session sends no duplicate or private reply" do
    owner = owner(reply_to: nil)
    session = actor()
    generation = make_ref()
    result = snapshot(1)
    owner_ref = Process.monitor(owner)
    assert :ok = Completion.register_session(owner, session)
    assert :ok = Completion.begin_request(owner, generation, result)
    assert :ok = Completion.finish(owner, generation, {:ok, result}, result)
    assert_receive {:managed_agents_session, ^result}
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    refute_receive {:managed_agents_session, _}
    refute_receive {:session_completion, ^owner, _}
  end

  test "legacy timeout is unarmed through initialization then arm_timeout expires the request" do
    owner = owner(timeout: 0)
    session = actor()
    assert :ok = Completion.register_session(owner, session)
    refute_receive {:session_completion, ^owner, _}, 30
    assert :ok = Completion.begin_request(owner, make_ref(), snapshot(0))
    assert :ok = Completion.arm_timeout(owner, 0)
    assert_receive {:managed_agents_session, result}
    assert result.turns == 0
    assert_receive {:session_completion, ^owner, {:error, :timeout}}
  end

  test "absolute deadline is armed before initialization has any snapshot" do
    assert {:ok, owner} =
             Completion.start(caller: self(), notify: self(), deadline: now() + 20)

    ref = Process.monitor(owner)
    assert_receive {:session_completion, ^owner, {:error, :timeout}}
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
    refute_receive {:managed_agents_session, _}
  end

  test "caller death reaps session and worker without publishing to a dead recipient" do
    test = self()

    caller =
      spawn(fn ->
        {:ok, owner} = Completion.start(caller: self(), notify: self())
        session = actor()
        worker = actor()
        :ok = Completion.register_session(owner, session)
        :ok = Completion.register_worker(owner, worker)
        send(test, {:owned, owner, session, worker})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:owned, owner, session, worker}
    refs = for pid <- [owner, session, worker], do: {Process.monitor(pid), pid}
    Process.exit(caller, :kill)
    for {ref, pid} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _})
  end

  defp owner(opts \\ []) do
    assert {:ok, owner} = Completion.start(Keyword.merge([caller: self(), notify: self()], opts))
    on_exit(fn -> Completion.abort(owner, :shutdown) end)
    owner
  end

  defp delivery(owner) do
    receive do
      {:managed_agents_session, result} -> {:notify, result}
      {:session_completion, ^owner, result} -> {:completion, result}
    after
      1_000 -> flunk("missing completion delivery")
    end
  end

  defp actor, do: spawn(fn -> receive do: (:stop -> :ok) end)
  defp now, do: System.monotonic_time(:millisecond)

  defp snapshot(turns) do
    usage =
      if turns == 0 do
        Usage.zero()
      else
        {:ok, usage} =
          Usage.new(%{
            input_tokens: 12,
            output_tokens: 4,
            cache_read_input_tokens: 3,
            cache_creation_input_tokens: 2,
            input_token_basis: :uncached
          })

        usage
      end

    %SessionResult{
      session_id: "same-session",
      terminal: :requires_action,
      stop_reason: %{"type" => "native-stop"},
      usage: usage,
      turns: turns
    }
    |> Map.put(:in_flight, :unknown)
  end
end
