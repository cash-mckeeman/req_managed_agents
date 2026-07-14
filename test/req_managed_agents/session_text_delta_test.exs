defmodule ReqManagedAgents.SessionTextDeltaTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Session

  # Handler module (fn handlers don't receive handle_event); context carries the test pid.
  defmodule Recorder do
    @behaviour ReqManagedAgents.Handler
    @impl true
    def handle_tool_call(_name, _input, _ctx), do: {:ok, "ok"}
    @impl true
    def handle_event(ev, test_pid, _info), do: send(test_pid, {:handler_event, ev})
  end

  defmodule DeltaProvider do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(_opts, _sub), do: {:ok, %{}}
    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}
    @impl true
    def poll_turn(conn, _input) do
      {:ok, [%{"type" => "say", "text" => "hello"}, %{"type" => "stop"}], conn}
    end

    @impl true
    def normalize(events) do
      %ReqManagedAgents.TurnResult{terminal: :end_turn, stop_reason: "end_turn", events: events}
    end

    @impl true
    def text_delta(%{"type" => "say", "text" => t}), do: t
    def text_delta(_), do: nil

    @impl true
    def session_id(_conn), do: nil
    @impl true
    def ref(_conn), do: nil
    @impl true
    def consumer(_conn), do: nil
    @impl true
    def resumed?(_conn), do: false
  end

  test "synthetic rma.text_delta follows the raw event to the handler, never into events" do
    assert {:ok, result} =
             Session.run(DeltaProvider, handler: Recorder, context: self())

    assert_received {:handler_event, %{"type" => "say", "text" => "hello"}}
    assert_received {:handler_event, %{"type" => "rma.text_delta", "text" => "hello"}}
    assert_received {:handler_event, %{"type" => "stop"}}
    refute Enum.any?(result.events, &(&1["type"] == "rma.text_delta"))
  end
end
