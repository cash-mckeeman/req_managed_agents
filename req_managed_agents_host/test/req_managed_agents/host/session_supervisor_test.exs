defmodule ReqManagedAgents.Host.SessionSupervisorTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Host.{Config, SessionServer, SessionSupervisor}
  alias ReqManagedAgents.Host.Store.ETS

  defp ets_store do
    name = :"session_supervisor_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ETS.start_link(name: name)
    {ETS, name: name}
  end

  defp config do
    {:ok, cfg} = Config.new(provider: StubProvider, handler: EchoHandler, store: ets_store())
    cfg
  end

  defp external_id, do: "ext-#{System.unique_integer([:positive])}"

  test "concurrent start_or_get for the same external_id yields one unique pid" do
    id = external_id()
    cfg = config()

    pids =
      1..20
      |> Task.async_stream(fn _ -> SessionSupervisor.start_or_get(id, cfg) end)
      |> Enum.map(fn {:ok, {:ok, pid}} -> pid end)

    [pid] = Enum.uniq(pids)
    assert Process.alive?(pid)
    assert [{^pid, nil}] = Registry.lookup(ReqManagedAgents.Host.Registry, id)
  end

  test "different external_ids yield different pids" do
    cfg = config()

    {:ok, pid_a} = SessionSupervisor.start_or_get(external_id(), cfg)
    {:ok, pid_b} = SessionSupervisor.start_or_get(external_id(), cfg)

    refute pid_a == pid_b
  end

  test "killing one session server does not stop a sibling" do
    cfg = config()

    {:ok, pid_a} = SessionSupervisor.start_or_get(external_id(), cfg)
    {:ok, pid_b} = SessionSupervisor.start_or_get(external_id(), cfg)

    ref_b = Process.monitor(pid_b)

    Process.exit(pid_a, :kill)

    refute_receive {:DOWN, ^ref_b, :process, ^pid_b, _}, 200
    assert Process.alive?(pid_b)
    assert {:ok, _} = SessionServer.deliver(pid_b, "still alive")
  end
end
