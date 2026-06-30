defmodule ReqManagedAgents.SessionResilienceTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Session
  alias ReqManagedAgents.FakeProviders.{FailingOpen, CrashingPoll, RequestResponse}

  test "open failure surfaces verbatim (no extra {:open_failed, _} wrapping)" do
    assert {:error, {:create_session_failed, :boom}} =
             Session.run(FailingOpen, handler: fn _, _, _ -> {:ok, "x"} end)
  end

  test "a provider raise in poll_turn surfaces as {:error, _} and does NOT kill the caller" do
    assert {:error, {:provider_error, %RuntimeError{}}} =
             Session.run(CrashingPoll, handler: fn _, _, _ -> {:ok, "x"} end)

    # If the linked Task crash had propagated, this process would already be dead.
    assert Process.alive?(self())
  end

  test "emits per-turn [:session, :tool_uses] telemetry carrying the tool ids" do
    ref = make_ref()

    :telemetry.attach(
      {__MODULE__, ref},
      [:req_managed_agents, :session, :tool_uses],
      fn _event, meas, meta, pid -> send(pid, {:tool_uses, meas, meta}) end,
      self()
    )

    ra = [
      %{"type" => "tool", "id" => "t1", "name" => "echo", "input" => %{}},
      %{"type" => "stop", "terminal" => :requires_action}
    ]

    Session.run(RequestResponse,
      handler: fn _, _, _ -> {:ok, "r"} end,
      turns: [ra, [%{"type" => "stop", "terminal" => :end_turn}]]
    )

    assert_received {:tool_uses, %{tool_use_count: 1}, %{tool_use_ids: ["t1"]}}
    :telemetry.detach({__MODULE__, ref})
  end
end
