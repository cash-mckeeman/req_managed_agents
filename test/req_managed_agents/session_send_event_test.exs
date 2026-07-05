defmodule ReqManagedAgents.SessionSendEventTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.{Event, Session}

  # Streaming fake that records pushed inputs instead of scripting turns.
  defmodule PushRecorder do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :streaming
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, subscriber) do
      ref = make_ref()
      send(subscriber, {:managed_agents, ref, :connected})
      {:ok, %{test_pid: opts[:test_pid], ref: ref}}
    end

    @impl true
    def kickoff_input(_opts), do: [:kickoff]
    @impl true
    def user_input(text), do: [{:user, text}]
    @impl true
    def resume_input(_uses, results), do: [{:resume, results}]
    @impl true
    def push_input(conn, events) do
      send(conn.test_pid, {:pushed, events})
      :ok
    end

    @impl true
    def turn_boundary?(_), do: false
    @impl true
    def normalize(events), do: %ReqManagedAgents.TurnResult{terminal: :terminated, events: events}
  end

  test "send_event/2 pushes the raw event on a streaming session" do
    {:ok, pid} = Session.start_link(PushRecorder, handler: fn _, _, _ -> {:ok, ""} end, test_pid: self())
    assert_receive {:pushed, [:kickoff]}

    event = Event.tool_confirmation("tu_1", :allow)
    assert :ok = Session.send_event(pid, event)
    assert_receive {:pushed, [^event]}
  end

  test "send_event/2 on a :request_response session is unsupported" do
    {:ok, pid} =
      Session.start_link(ReqManagedAgents.FakeProviders.RequestResponse,
        handler: fn _, _, _ -> {:ok, ""} end,
        turns: [[%{"type" => "stop", "terminal" => :end_turn}]]
      )

    assert {:error, :unsupported} = Session.send_event(pid, %{"type" => "user.message"})
  end
end
