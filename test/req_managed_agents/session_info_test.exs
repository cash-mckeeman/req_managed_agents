defmodule ReqManagedAgents.SessionInfoTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.{SessionInfo, ToolUse, TurnResult}

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

  # streaming fake whose conn carries a session_id — covers the per-event
  # forward_raw path ({:managed_agents, ref, {:event, ev}}) that InfoRR misses.
  defmodule InfoStreaming do
    @behaviour ReqManagedAgents.Provider

    @impl true
    def mode, do: :streaming
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}

    @impl true
    def open(opts, subscriber) do
      {:ok, agent} = Agent.start_link(fn -> opts[:turns] || [] end)
      ref = make_ref()
      send(subscriber, {:managed_agents, ref, :connected})
      {:ok, %{agent: agent, subscriber: subscriber, ref: ref, session_id: "sess-stream-1"}}
    end

    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}

    @impl true
    def push_input(conn, _input) do
      turn =
        Agent.get_and_update(conn.agent, fn
          [t | rest] -> {t, rest}
          [] -> {[%{"type" => "stop", "terminal" => :end_turn}], []}
        end)

      Enum.each(turn, fn ev ->
        send(conn.subscriber, {:managed_agents, conn.ref, {:event, ev}})
      end)

      :ok
    end

    @impl true
    def turn_boundary?(%{"type" => "stop"}), do: true
    def turn_boundary?(_), do: false

    @impl true
    defdelegate normalize(events), to: ReqManagedAgents.FakeProviders.Shared
  end

  # streaming fake that drops its first push; reconnect/3 hands back a conn carrying a
  # DIFFERENT session_id — asserting the Session rebuilds its info from the NEW conn.
  defmodule ReconnectNewSid do
    @behaviour ReqManagedAgents.Provider

    @impl true
    def mode, do: :streaming
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}

    @impl true
    def open(opts, subscriber) do
      {:ok, agent} =
        Agent.start_link(fn ->
          %{turns: opts[:turns] || [], pending: opts[:pending] || [], dropped: false}
        end)

      ref = make_ref()
      send(subscriber, {:managed_agents, ref, :connected})
      {:ok, %{agent: agent, subscriber: subscriber, ref: ref, session_id: "sid-before-drop"}}
    end

    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}

    @impl true
    def push_input(conn, _input) do
      drop? =
        Agent.get_and_update(conn.agent, fn st -> {not st.dropped, %{st | dropped: true}} end)

      if drop? do
        send(conn.subscriber, {:managed_agents, conn.ref, {:error, :stream_dropped}})
      else
        turn =
          Agent.get_and_update(conn.agent, fn
            %{turns: [t | rest]} = st -> {t, %{st | turns: rest}}
            %{turns: []} = st -> {[%{"type" => "stop", "terminal" => :end_turn}], st}
          end)

        Enum.each(turn, fn ev ->
          send(conn.subscriber, {:managed_agents, conn.ref, {:event, ev}})
        end)
      end

      :ok
    end

    @impl true
    def turn_boundary?(%{"type" => "stop"}), do: true
    def turn_boundary?(_), do: false

    @impl true
    def reconnect(conn, subscriber, seen) do
      pending = Agent.get(conn.agent, & &1.pending)

      new_conn = %{
        conn
        | ref: make_ref(),
          subscriber: subscriber,
          session_id: "sid-after-reconnect"
      }

      {:ok, new_conn, pending, seen}
    end

    @impl true
    defdelegate normalize(events), to: ReqManagedAgents.FakeProviders.Shared
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

  test "streaming: 4-arity handle_tool_call and 3-arity handle_event receive SessionInfo per event" do
    turns = [
      [
        %{"type" => "tool", "id" => "tu_1", "name" => "whoami", "input" => %{}},
        %{"type" => "stop", "terminal" => :requires_action}
      ],
      [%{"type" => "stop", "terminal" => :end_turn}]
    ]

    assert {:ok, result} =
             ReqManagedAgents.Session.run(InfoStreaming,
               handler: FourArityHandler,
               context: %{test_pid: self()},
               turns: turns
             )

    assert_received {:tool_saw_info,
                     %SessionInfo{session_id: "sess-stream-1", provider: InfoStreaming}}

    # handle_event/3 fires once per pushed event (tool, requires_action stop, end_turn stop)
    assert_received {:event_saw_info, "sess-stream-1"}
    assert_received {:event_saw_info, "sess-stream-1"}
    assert_received {:event_saw_info, "sess-stream-1"}
    assert result.session_id == "sess-stream-1"
  end

  test "reconnect: handler sees the NEW conn's session_id after a stream drop" do
    test_pid = self()

    # kickoff push is dropped → reconnect/3 returns a conn with a different session_id and
    # the unanswered tool to redrive → the handler must observe the post-reconnect id.
    {:ok, pid} =
      ReqManagedAgents.Session.start_link(ReconnectNewSid,
        handler: fn _name, _input, _ctx, %SessionInfo{session_id: sid} ->
          send(test_pid, {:tool_saw_sid, sid})
          {:ok, "ok"}
        end,
        notify: test_pid,
        pending: [%ToolUse{id: "t1", name: "echo", input: %{"x" => 1}}],
        turns: [[%{"type" => "stop", "terminal" => :end_turn}]]
      )

    assert_receive {:tool_saw_sid, "sid-after-reconnect"}, 2000

    assert_receive {:managed_agents_session,
                    %ReqManagedAgents.SessionResult{
                      terminal: :end_turn,
                      session_id: "sid-after-reconnect"
                    }},
                   2000

    assert Process.alive?(pid)
  end
end
