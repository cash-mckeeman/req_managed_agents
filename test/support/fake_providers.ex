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
end
