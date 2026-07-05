defmodule ReqManagedAgents.SessionMetadataTest do
  use ExUnit.Case
  alias ReqManagedAgents.FakeProviders.RequestResponse
  alias ReqManagedAgents.Session

  defmodule InfoRecorder do
    @behaviour ReqManagedAgents.Handler
    @impl true
    def handle_tool_call(_n, _i, _c), do: {:ok, "ok"}
    @impl true
    def handle_event(_ev, test_pid, info), do: send(test_pid, {:info, info})
  end

  @end_turn [%{"type" => "stop", "terminal" => :end_turn}]

  test "model_config metadata reaches telemetry metadata" do
    handler_id = "session-metadata-telemetry-#{System.unique_integer()}"
    test = self()

    :telemetry.attach(
      handler_id,
      [:req_managed_agents, :session, :terminal],
      fn _event, _meas, meta, _cfg -> send(test, {:telemetry_meta, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _} =
      Session.run(RequestResponse,
        handler: fn _, _, _ -> {:ok, ""} end,
        turns: [@end_turn],
        telemetry_metadata: %{step_id: "step_1"},
        model_config: %{metadata: %{mimir_request_id: "req_9", decision_id: "rd_1"}}
      )

    assert_receive {:telemetry_meta, meta}
    assert meta.mimir_request_id == "req_9"
    assert meta.decision_id == "rd_1"
    assert meta.step_id == "step_1"
  end

  test "model_config metadata reaches handle_event via SessionInfo" do
    {:ok, _} =
      Session.run(RequestResponse,
        handler: InfoRecorder,
        context: self(),
        turns: [@end_turn],
        model_config: %{metadata: %{mimir_request_id: "req_9"}}
      )

    assert_receive {:info, %ReqManagedAgents.SessionInfo{metadata: %{mimir_request_id: "req_9"}}}
  end
end
