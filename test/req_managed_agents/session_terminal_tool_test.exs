defmodule ReqManagedAgents.SessionTerminalToolTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Session
  alias ReqManagedAgents.{SessionResult, ToolUse, TurnResult, Usage}

  # :request_response provider: pops scripted turns, reports every input to the test.
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
    def poll_turn(%{turns: turns, test_pid: t} = c, input) do
      send(t, {:polled, input})

      case turns do
        [turn | rest] -> {:ok, turn, %{c | turns: rest}}
        [] -> {:ok, [%{"type" => "stop", "terminal" => :end_turn}], c}
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

  @end_turn [%{"type" => "stop", "terminal" => :end_turn}]
  @submit_turn [
    %{"type" => "tool", "id" => "s1", "name" => "submit_answer", "input" => %{}},
    %{"type" => "stop", "terminal" => :requires_action}
  ]

  @reprompt "You returned a response without calling submit_answer. You MUST call " <>
              "submit_answer now to finish — produce the result via submit_answer."

  defp run(turns, opts) do
    Session.run(
      Recording,
      [
        handler: fn _n, _i, _c -> {:ok, "ok"} end,
        test_pid: self(),
        turns: turns,
        require_terminal_tool: true,
        terminal_tool: "submit_answer"
      ] ++ opts
    )
  end

  test "end_turn without the terminal tool re-prompts, then finishes :no_terminal_tool" do
    assert {:ok, %SessionResult{terminal: :end_turn, stop_reason: :no_terminal_tool, turns: 3}} =
             run([@end_turn, @end_turn, @end_turn], [])

    assert_received {:polled, :kickoff}
    assert_received {:polled, {:user, @reprompt}}
    assert_received {:polled, {:user, @reprompt}}
    refute_received {:polled, _}
  end

  test "a re-prompt that produces the terminal tool finishes normally" do
    assert {:ok, %SessionResult{terminal: :end_turn, stop_reason: "end_turn", turns: 3}} =
             run([@end_turn, @submit_turn, @end_turn], [])

    assert_received {:polled, :kickoff}
    assert_received {:polled, {:user, @reprompt}}
    assert_received {:polled, {:resume, [_]}}
  end

  test "terminal tool called during the run — no re-prompt" do
    assert {:ok, %SessionResult{terminal: :end_turn, stop_reason: "end_turn", turns: 2}} =
             run([@submit_turn, @end_turn], [])

    refute_received {:polled, {:user, _}}
  end

  test "max_reprompts: 0 finishes :no_terminal_tool immediately" do
    assert {:ok, %SessionResult{stop_reason: :no_terminal_tool, turns: 1}} =
             run([@end_turn], max_reprompts: 0)
  end

  test "require_terminal_tool without terminal_tool is rejected at start" do
    assert {:error, {:invalid_opts, :terminal_tool_required}} =
             Session.run(Recording,
               handler: fn _, _, _ -> {:ok, ""} end,
               test_pid: self(),
               turns: [],
               require_terminal_tool: true
             )
  end
end
