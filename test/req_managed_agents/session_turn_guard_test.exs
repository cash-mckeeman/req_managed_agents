defmodule ReqManagedAgents.SessionTurnGuardTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.FakeProviders.RequestResponse
  alias ReqManagedAgents.Session
  alias ReqManagedAgents.SessionResult

  @tool_turn [
    %{"type" => "tool", "id" => "t1", "name" => "echo", "input" => %{}},
    %{"type" => "stop", "terminal" => :requires_action}
  ]
  @end_turn [%{"type" => "stop", "terminal" => :end_turn}]

  defp ok_handler, do: fn _n, _i, _c -> {:ok, "x"} end

  test "guard returning :cont leaves the run unaffected" do
    assert {:ok, %SessionResult{terminal: :end_turn, turns: 2}} =
             Session.run(RequestResponse,
               handler: ok_handler(),
               turns: [@tool_turn, @end_turn],
               turn_guard: fn _ -> :cont end
             )
  end

  test "guard halt terminates: {:error, {:halted, reason}} + :terminated notify" do
    assert {:error, {:halted, {:budget_exceeded, 2}}} =
             Session.run(RequestResponse,
               handler: ok_handler(),
               notify: self(),
               turns: [@tool_turn, @end_turn],
               turn_guard: fn %{turns: n} ->
                 if n >= 2, do: {:halt, {:budget_exceeded, n}}, else: :cont
               end
             )

    assert_received {:managed_agents_session, %SessionResult{terminal: :terminated, turns: 2}}
  end

  test "guard payload is plain data: usage map (not struct), turns, session_id" do
    test = self()

    {:ok, _} =
      Session.run(RequestResponse,
        handler: ok_handler(),
        turns: [@end_turn],
        turn_guard: fn payload ->
          send(test, {:guard_saw, payload})
          :cont
        end
      )

    assert_received {:guard_saw, payload}
    assert %{usage: usage, turns: 1, session_id: _} = payload
    refute is_struct(usage)
    assert %{input_tokens: 1, output_tokens: 1, raw: [_]} = usage
  end

  test "invalid turn_guard is rejected at start" do
    assert {:error, {:invalid_turn_guard, :nope}} =
             Session.run(RequestResponse, handler: ok_handler(), turns: [], turn_guard: :nope)
  end
end
