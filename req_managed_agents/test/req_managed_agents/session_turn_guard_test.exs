defmodule ReqManagedAgents.SessionTurnGuardTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.FakeProviders.{RequestResponse, Streaming}
  alias ReqManagedAgents.Session
  alias ReqManagedAgents.SessionResult
  alias ReqManagedAgents.{ToolUse, TurnResult, Usage}

  # Recording provider: request/response, captures every poll_turn input, supports
  # payloads for the re-prompt guard scenario.
  defmodule Recording do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, _sub), do: {:ok, %{turns: opts[:turns] || [], test_pid: opts[:test_pid]}}
    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}
    @impl true
    def poll_turn(%{turns: turns, test_pid: t} = c, _input) do
      case turns do
        [turn | rest] -> {:ok, turn, %{c | turns: rest}}
        [] -> {:ok, [%{"type" => "stop", "terminal" => :end_turn}], %{c | test_pid: t}}
      end
    end

    @impl true
    def normalize(events) do
      customs =
        for %{"type" => "tool"} = e <- events,
            do: %ToolUse{id: e["id"], name: e["name"], input: e["input"] || %{}}

      terminal =
        Enum.find_value(events, :terminated, fn
          %{"type" => "stop", "terminal" => t} -> t
          _ -> nil
        end)

      %TurnResult{
        terminal: terminal,
        stop_reason: to_string(terminal),
        custom_tool_uses: customs,
        usage: %Usage{input_tokens: 1, output_tokens: 1, raw: [%{}]},
        events: events
      }
    end

    @impl true
    def session_id(_conn), do: nil
    @impl true
    def ref(_conn), do: nil
    @impl true
    def consumer(_conn), do: nil
    @impl true
    def resumed?(_conn), do: false
  end

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

  test "guard payload carries the accumulated %Usage{} struct, turns, session_id" do
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
    assert %Usage{input_tokens: 1, output_tokens: 1, raw: [_]} = usage
  end

  test "invalid turn_guard is rejected at start" do
    assert {:error, {:invalid_turn_guard, :nope}} =
             Session.run(RequestResponse, handler: ok_handler(), turns: [], turn_guard: :nope)
  end

  # (a) Guard on the STREAMING path: halt-at-turns>=2 on the Streaming fake.
  test "guard halts on the streaming path" do
    assert {:error, {:halted, {:budget_exceeded, 2}}} =
             Session.run(Streaming,
               handler: ok_handler(),
               notify: self(),
               turns: [@tool_turn, @end_turn],
               turn_guard: fn %{turns: n} ->
                 if n >= 2, do: {:halt, {:budget_exceeded, n}}, else: :cont
               end
             )

    assert_received {:managed_agents_session, %SessionResult{terminal: :terminated, turns: 2}}
  end

  # (b) Guard wins over max_turns when both trip on the same turn.
  test "guard halt wins over max_turns when both fire on the same turn" do
    assert {:error, {:halted, :guard_wins}} =
             Session.run(RequestResponse,
               handler: ok_handler(),
               turns: [@tool_turn, @end_turn],
               max_turns: 2,
               turn_guard: fn %{turns: n} ->
                 if n >= 2, do: {:halt, :guard_wins}, else: :cont
               end
             )
  end

  # (c) Guard fires on re-prompt turns: payloads monotonically increasing for all 3 turns.
  test "guard fires on terminal-tool re-prompt turns" do
    test = self()

    Session.run(
      Recording,
      handler: ok_handler(),
      test_pid: self(),
      turns: [@end_turn, @end_turn, @end_turn],
      require_terminal_tool: true,
      terminal_tool: "submit_answer",
      max_reprompts: 2,
      turn_guard: fn %{turns: n} = payload ->
        send(test, {:guard_payload, n, payload})
        :cont
      end
    )

    assert_received {:guard_payload, 1, _}
    assert_received {:guard_payload, 2, _}
    assert_received {:guard_payload, 3, _}
    refute_received {:guard_payload, _, _}
  end
end
