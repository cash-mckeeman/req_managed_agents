defmodule ReqManagedAgents.SessionInfoTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.{SessionInfo, TurnResult}

  # request_response fake whose conn carries a session_id (like both real providers post-0.3).
  defmodule InfoRR do
    @behaviour ReqManagedAgents.Provider

    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(_opts, _subscriber), do: {:ok, %{session_id: "sess-info-1"}}
    @impl true
    def kickoff_input(_opts), do: [:kickoff]
    @impl true
    def user_input(text), do: [{:user, text}]
    @impl true
    def resume_input(_uses, _results), do: [:resume]

    @impl true
    def poll_turn(conn, [:kickoff]) do
      {:ok,
       [
         %{"type" => "tool", "id" => "tu_1", "name" => "whoami", "input" => %{}},
         %{"type" => "stop", "terminal" => :requires_action}
       ], conn}
    end

    def poll_turn(conn, [:resume]) do
      {:ok, [%{"type" => "stop", "terminal" => :end_turn}], conn}
    end

    @impl true
    def normalize(events) do
      customs =
        for %{"type" => "tool", "id" => id, "name" => n, "input" => i} <- events,
            do: %ReqManagedAgents.ToolUse{id: id, name: n, input: i}

      terminal =
        case List.last(events) do
          %{"type" => "stop", "terminal" => t} -> t
          _ -> :terminated
        end

      %TurnResult{
        terminal: terminal,
        stop_reason: to_string(terminal),
        text: "",
        custom_tool_uses: customs,
        server_tool_uses: [],
        usage: nil,
        events: events
      }
    end
  end

  defmodule FourArityHandler do
    @behaviour ReqManagedAgents.Handler

    @impl true
    def handle_tool_call(_name, _input, _ctx), do: {:ok, "three-arity fallback"}

    @impl true
    def handle_tool_call("whoami", _input, %{test_pid: pid}, %SessionInfo{} = info) do
      send(pid, {:tool_saw_info, info})
      {:ok, "session #{info.session_id}"}
    end

    @impl true
    def handle_event(_ev, %{test_pid: pid}, %SessionInfo{} = info) do
      send(pid, {:event_saw_info, info.session_id})
      :ok
    end
  end

  defmodule ThreeArityHandler do
    @behaviour ReqManagedAgents.Handler

    @impl true
    def handle_tool_call("whoami", _input, %{test_pid: pid}) do
      send(pid, :three_arity_called)
      {:ok, "legacy"}
    end

    @impl true
    def handle_event(_ev, _ctx), do: :ok
  end

  test "module handler: 4-arity handle_tool_call and 3-arity handle_event receive SessionInfo" do
    assert {:ok, result} =
             ReqManagedAgents.Session.run(InfoRR,
               handler: FourArityHandler,
               context: %{test_pid: self()},
               prompt: "go"
             )

    assert_received {:tool_saw_info, %SessionInfo{session_id: "sess-info-1", provider: InfoRR}}
    assert_received {:event_saw_info, "sess-info-1"}
    assert result.session_id == "sess-info-1"
  end

  test "module handler: 3-arity handler still works unchanged (fallback dispatch)" do
    assert {:ok, result} =
             ReqManagedAgents.Session.run(InfoRR,
               handler: ThreeArityHandler,
               context: %{test_pid: self()},
               prompt: "go"
             )

    assert_received :three_arity_called
    assert result.terminal == :end_turn
  end

  test "fn handler: 4-arity fun receives SessionInfo; 3-arity fun still works" do
    test_pid = self()

    assert {:ok, _} =
             ReqManagedAgents.Session.run(InfoRR,
               handler: fn _name, _input, _ctx, %SessionInfo{session_id: sid} ->
                 send(test_pid, {:fn4, sid})
                 {:ok, "ok"}
               end,
               context: %{},
               prompt: "go"
             )

    assert_received {:fn4, "sess-info-1"}

    assert {:ok, _} =
             ReqManagedAgents.Session.run(InfoRR,
               handler: fn _name, _input, _ctx ->
                 send(test_pid, :fn3)
                 {:ok, "ok"}
               end,
               context: %{},
               prompt: "go"
             )

    assert_received :fn3
  end
end
