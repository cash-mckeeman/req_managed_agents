defmodule ReqManagedAgents.SessionTimeoutCancelTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Session

  # :request_response provider whose poll blocks forever — simulates a long
  # in-flight AgentCore invoke holding a Finch stream open.
  defmodule BlockingPoll do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, _subscriber), do: {:ok, %{test_pid: opts[:test_pid]}}
    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}
    @impl true
    def poll_turn(conn, _input) do
      send(conn.test_pid, {:poll_started, self()})
      Process.sleep(:infinity)
    end

    @impl true
    def normalize(_events), do: %ReqManagedAgents.TurnResult{terminal: :end_turn}
    @impl true
    def session_id(_conn), do: nil
    @impl true
    def ref(_conn), do: nil
    @impl true
    def consumer(_conn), do: nil
    @impl true
    def resumed?(_conn), do: false
  end

  test "run/2 timeout shuts down the in-flight poll task" do
    assert {:error, :timeout} =
             Session.run(BlockingPoll,
               handler: fn _n, _i, _c -> {:ok, ""} end,
               test_pid: self(),
               timeout: 100
             )

    assert_receive {:poll_started, task_pid}, 1_000
    ref = Process.monitor(task_pid)
    # Monitoring an already-dead pid still delivers :DOWN immediately, so this
    # asserts "dead now or dies promptly" either way.
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, 1_000
  end
end
