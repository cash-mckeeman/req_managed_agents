defmodule ReqManagedAgents.SessionLiveEventsTest do
  use ExUnit.Case, async: true

  # request_response provider that delivers events LIVE (like BedrockAgentCore
  # post-MIM-50): poll_turn sends {:provider_event, ev} to the subscriber
  # captured at open, then returns the same events as the turn result.
  defmodule LiveRR do
    @behaviour ReqManagedAgents.Provider
    alias ReqManagedAgents.TurnResult

    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, subscriber), do: {:ok, %{subscriber: subscriber, opts: opts}}
    @impl true
    def kickoff_input(_opts), do: [:kickoff]
    @impl true
    def user_input(text), do: [{:user, text}]
    @impl true
    def resume_input(_uses, _results), do: [:resume]

    @impl true
    def poll_turn(conn, _input) do
      events = [
        %{"messageStart" => %{"role" => "assistant"}},
        %{"messageStop" => %{"stopReason" => "end_turn"}}
      ]

      Enum.each(events, &send(conn.subscriber, {:provider_event, &1}))
      {:ok, events, conn}
    end

    @impl true
    def normalize(events) do
      %TurnResult{
        terminal: :end_turn,
        stop_reason: "end_turn",
        text: "",
        custom_tool_uses: [],
        server_tool_uses: [],
        usage: nil,
        events: events
      }
    end
  end

  # Same provider WITHOUT live delivery — the batch path must keep working.
  defmodule BatchRR do
    @behaviour ReqManagedAgents.Provider
    alias ReqManagedAgents.TurnResult

    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, subscriber), do: {:ok, %{subscriber: subscriber, opts: opts}}
    @impl true
    def kickoff_input(_opts), do: [:kickoff]
    @impl true
    def user_input(text), do: [{:user, text}]
    @impl true
    def resume_input(_uses, _results), do: [:resume]

    @impl true
    def poll_turn(conn, _input) do
      {:ok,
       [
         %{"messageStart" => %{"role" => "assistant"}},
         %{"messageStop" => %{"stopReason" => "end_turn"}}
       ], conn}
    end

    @impl true
    def normalize(events) do
      %TurnResult{
        terminal: :end_turn,
        stop_reason: "end_turn",
        text: "",
        custom_tool_uses: [],
        server_tool_uses: [],
        usage: nil,
        events: events
      }
    end
  end

  defmodule CountingHandler do
    @behaviour ReqManagedAgents.Handler

    @impl true
    def handle_tool_call(_name, _input, _ctx), do: {:ok, "unused"}

    @impl true
    def handle_event(ev, %{test_pid: pid}) do
      send(pid, {:handler_saw, ev})
      :ok
    end
  end

  test "live provider: handler sees each event exactly once (no batch double-delivery)" do
    assert {:ok, result} =
             ReqManagedAgents.Session.run(LiveRR,
               handler: CountingHandler,
               context: %{test_pid: self()},
               prompt: "go"
             )

    assert result.terminal == :end_turn
    assert_received {:handler_saw, %{"messageStart" => _}}
    assert_received {:handler_saw, %{"messageStop" => _}}
    refute_received {:handler_saw, _}
    # Canonical record still carries the turn's events.
    assert length(result.events) == 2
  end

  test "batch provider: handler still sees events exactly once via batch delivery" do
    assert {:ok, result} =
             ReqManagedAgents.Session.run(BatchRR,
               handler: CountingHandler,
               context: %{test_pid: self()},
               prompt: "go"
             )

    assert result.terminal == :end_turn
    assert_received {:handler_saw, %{"messageStart" => _}}
    assert_received {:handler_saw, %{"messageStop" => _}}
    refute_received {:handler_saw, _}
  end

  test "live events emit [:req_managed_agents, :stream, :event] telemetry with the envelope type" do
    test_pid = self()
    handler_id = "live-events-telemetry-#{inspect(self())}"

    :telemetry.attach(
      handler_id,
      [:req_managed_agents, :stream, :event],
      fn _event, _meas, meta, _cfg -> send(test_pid, {:stream_event_meta, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _} =
             ReqManagedAgents.Session.run(LiveRR,
               handler: CountingHandler,
               context: %{test_pid: self()},
               prompt: "go",
               telemetry_metadata: %{mim: 50}
             )

    assert_received {:stream_event_meta, %{type: "messageStart", mim: 50}}
    assert_received {:stream_event_meta, %{type: "messageStop", mim: 50}}
  end
end
