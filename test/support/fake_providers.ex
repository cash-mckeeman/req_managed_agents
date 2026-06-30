defmodule ReqManagedAgents.FakeProviders do
  @moduledoc false
  # Fake providers for the Session loop tests. A "turn" is a list of fake events:
  #   %{"type" => "tool", "id" => , "name" => , "input" => }  — a custom (client-side) tool use
  #   %{"type" => "stop", "terminal" => :requires_action | :end_turn | :terminated}

  defmodule Shared do
    def normalize(events) do
      customs =
        for %{"type" => "tool"} = e <- events, do: %{id: e["id"], name: e["name"], input: e["input"]}

      terminal =
        Enum.find_value(events, :terminated, fn
          %{"type" => "stop", "terminal" => t} -> t
          _ -> nil
        end)

      %{terminal: terminal, stop_reason: to_string(terminal), custom_tool_uses: customs,
        server_tool_uses: [], text: "", events: events}
    end
  end

  defmodule RequestResponse do
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, _subscriber), do: {:ok, %{turns: opts[:turns] || []}}
    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}
    @impl true
    def poll_turn(%{turns: [t | rest]} = c, _input), do: {:ok, t, %{c | turns: rest}}
    def poll_turn(%{turns: []} = c, _input), do: {:ok, [%{"type" => "stop", "terminal" => :end_turn}], c}
    @impl true
    defdelegate normalize(events), to: Shared
  end

  defmodule Streaming do
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
      {:ok, %{agent: agent, subscriber: subscriber, ref: ref}}
    end
    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}
    @impl true
    def push_input(conn, _input) do
      turn = Agent.get_and_update(conn.agent, fn
        [t | rest] -> {t, rest}
        [] -> {[%{"type" => "stop", "terminal" => :end_turn}], []}
      end)
      Enum.each(turn, fn ev -> send(conn.subscriber, {:managed_agents, conn.ref, {:event, ev}}) end)
      :ok
    end
    @impl true
    def turn_boundary?(%{"type" => "stop"}), do: true
    def turn_boundary?(_), do: false
    @impl true
    defdelegate normalize(events), to: Shared
  end

  # Streaming fake that drops the very first push (simulating a mid-turn stream loss), then
  # serves `opts[:turns]` normally; its `reconnect/3` returns `opts[:pending]` to re-drive.
  defmodule ReconnectingStreaming do
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :streaming
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, subscriber) do
      {:ok, agent} =
        Agent.start_link(fn -> %{turns: opts[:turns] || [], pending: opts[:pending] || [], dropped: false} end)

      ref = make_ref()
      send(subscriber, {:managed_agents, ref, :connected})
      {:ok, %{agent: agent, subscriber: subscriber, ref: ref}}
    end
    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}
    @impl true
    def push_input(conn, _input) do
      drop? = Agent.get_and_update(conn.agent, fn st -> {not st.dropped, %{st | dropped: true}} end)

      if drop? do
        send(conn.subscriber, {:managed_agents, conn.ref, {:error, :stream_dropped}})
      else
        turn =
          Agent.get_and_update(conn.agent, fn
            %{turns: [t | rest]} = st -> {t, %{st | turns: rest}}
            %{turns: []} = st -> {[%{"type" => "stop", "terminal" => :end_turn}], st}
          end)

        Enum.each(turn, fn ev -> send(conn.subscriber, {:managed_agents, conn.ref, {:event, ev}}) end)
      end

      :ok
    end
    @impl true
    def turn_boundary?(%{"type" => "stop"}), do: true
    def turn_boundary?(_), do: false
    @impl true
    def reconnect(conn, subscriber, seen) do
      pending = Agent.get(conn.agent, & &1.pending)
      {:ok, %{conn | ref: make_ref(), subscriber: subscriber}, pending, seen}
    end
    @impl true
    defdelegate normalize(events), to: Shared
  end

  # open/2 fails — to assert the Session surfaces the provider error verbatim.
  defmodule FailingOpen do
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :streaming
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(_opts, _sub), do: {:error, {:create_session_failed, :boom}}
    @impl true
    def kickoff_input(_), do: :k
    @impl true
    def user_input(_), do: :u
    @impl true
    def resume_input(_, results), do: {:resume, results}
    @impl true
    def push_input(_, _), do: :ok
    @impl true
    def turn_boundary?(_), do: true
    @impl true
    defdelegate normalize(events), to: Shared
  end

  # poll_turn/2 RAISES — to assert the Session surfaces it as {:error, _} without killing the caller.
  defmodule CrashingPoll do
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(_opts, _sub), do: {:ok, %{}}
    @impl true
    def kickoff_input(_), do: :k
    @impl true
    def user_input(_), do: :u
    @impl true
    def resume_input(_, results), do: {:resume, results}
    @impl true
    def poll_turn(_conn, _input), do: raise("boom in poll_turn")
    @impl true
    defdelegate normalize(events), to: Shared
  end
end
