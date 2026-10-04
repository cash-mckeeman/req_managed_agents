defmodule ReqManagedAgents.SessionRequiresActionRecoveryTest do
  @moduledoc """
  Issue #61: a `requires_action` turn can resolve ZERO `custom_tool_uses` when the
  provider's per-batch normalization can't find the ids its own idle event references
  (they live in an earlier, already-processed batch). Driving `resume_input([], [])` in
  that case posts an empty events list, which the real API 400s on
  ("events: value must contain at least 1 item"). The `Session` must never do that:
  it recovers via the provider's optional `pending_tool_uses/1` (keyed off the
  session's own accumulated history), and — if nothing is recoverable — surfaces a
  loud protocol-state error instead of the doomed empty resume.

  See `ReqManagedAgents.SessionRequiresActionRecoveryLiveShapeTest` for the same
  contract exercised against the real `ClaudeManagedAgents` provider over a
  live-shaped (Bypass) event stream.
  """
  use ExUnit.Case, async: true
  alias ReqManagedAgents.FakeProviders.{PendingRecoveryStreaming, Streaming}
  alias ReqManagedAgents.{Session, SessionResult}

  test "recovers unanswered tool uses via provider.pending_tool_uses/1 instead of sending an empty resume" do
    test = self()

    handler = fn name, input, _ctx ->
      send(test, {:tool_ran, name, input})
      {:ok, "r-#{name}"}
    end

    turn1 = [
      %{"type" => "tool", "id" => "t1", "name" => "a", "input" => %{}},
      %{"type" => "tool", "id" => "t2", "name" => "b", "input" => %{}},
      %{"type" => "stop", "terminal" => :requires_action}
    ]

    # The second idle references t2 again, but ITS OWN batch carries no "tool" event at
    # all — the referenced use lives entirely in turn1's already-processed batch.
    turn2 = [%{"type" => "stop", "terminal" => :requires_action}]

    assert {:ok, %SessionResult{terminal: :end_turn, custom_tool_uses: custom_tool_uses}} =
             Session.run(PendingRecoveryStreaming, handler: handler, turns: [turn1, turn2])

    assert_received {:tool_ran, "a", %{}}
    assert_received {:tool_ran, "b", %{}}
    # Recovered tool uses are re-run (no cached result to replay from) — the same
    # at-least-once contract `redrive/2` already applies on a reconnect.
    assert_received {:tool_ran, "b", %{}}

    # "b" (t2) was already accumulated when turn1 resolved AND re-appears via
    # `pending_tool_uses/1` recovery — the public SessionResult must not carry it twice.
    ids = Enum.map(custom_tool_uses, & &1.id)
    assert ids -- Enum.uniq(ids) == [], "expected no duplicate tool_use ids, got: #{inspect(ids)}"
    assert Enum.sort(Enum.uniq(ids)) == ["t1", "t2"]
    assert Enum.count(ids, &(&1 == "t1")) == 1
    assert Enum.count(ids, &(&1 == "t2")) == 1
  end

  test "emits [:session, :tool_uses] telemetry for recovered tool uses too" do
    ref = make_ref()

    :telemetry.attach(
      {__MODULE__, ref},
      [:req_managed_agents, :session, :tool_uses],
      fn _event, meas, meta, pid -> send(pid, {:tool_uses, meas, meta}) end,
      self()
    )

    turn1 = [
      %{"type" => "tool", "id" => "t1", "name" => "a", "input" => %{}},
      %{"type" => "stop", "terminal" => :requires_action}
    ]

    turn2 = [%{"type" => "stop", "terminal" => :requires_action}]

    Session.run(PendingRecoveryStreaming,
      handler: fn _, _, _ -> {:ok, "r"} end,
      turns: [turn1, turn2]
    )

    assert_received {:tool_uses, %{tool_use_count: 1}, %{tool_use_ids: ["t1"]}}
    assert_received {:tool_uses, %{tool_use_count: 0}, %{tool_use_ids: []}}
    assert_received {:tool_uses, %{tool_use_count: 1}, %{tool_use_ids: ["t1"]}}
    :telemetry.detach({__MODULE__, ref})
  end

  test "errors loudly instead of sending an empty resume when nothing is recoverable" do
    # Streaming has no pending_tool_uses/1 — recovery is unavailable.
    turn1 = [
      %{"type" => "tool", "id" => "t1", "name" => "a", "input" => %{}},
      %{"type" => "stop", "terminal" => :requires_action}
    ]

    turn2 = [%{"type" => "stop", "terminal" => :requires_action}]

    assert {:error, {:unresolved_requires_action, "requires_action"}} =
             Session.run(Streaming, handler: fn _, _, _ -> {:ok, "x"} end, turns: [turn1, turn2])
  end
end
