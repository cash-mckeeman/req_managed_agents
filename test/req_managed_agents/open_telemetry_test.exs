defmodule ReqManagedAgents.OpenTelemetryTest do
  use ExUnit.Case, async: false
  alias ReqManagedAgents.OpenTelemetry, as: OTel

  test "events/0 lists the stream/tool/session telemetry the bridge maps" do
    events = OTel.events()
    assert [:req_managed_agents, :stream, :event] in events
    assert [:req_managed_agents, :tool, :stop] in events
    assert [:req_managed_agents, :session, :terminal] in events
  end

  test "attributes_for dispatches each event to its gen_ai type + attrs" do
    assert {"chat", %{"gen_ai.operation.name" => "chat"}} =
             OTel.attributes_for([:req_managed_agents, :stream, :event], %{session_id: "s1"})

    assert {"tool_result", %{"gen_ai.operation.name" => "execute_tool"}} =
             OTel.attributes_for([:req_managed_agents, :tool, :stop], %{session_id: "s1", tool: "calc"})

    assert {"turn_complete", %{"gen_ai.response.finish_reasons" => ["end_turn"]}} =
             OTel.attributes_for([:req_managed_agents, :session, :terminal], %{session_id: "s1", terminal: :end_turn})
  end

  test "available?/0 reflects whether the OTel SDK is loaded (false in this lib's test env)" do
    assert OTel.available?() == Code.ensure_loaded?(:otel_tracer)
  end

  test "attach/1 no-ops gracefully without the OTel SDK and never raises" do
    result = OTel.attach("t-otel-test")
    assert result == :ok or result == {:error, :opentelemetry_unavailable}
  after
    OTel.detach("t-otel-test")
  end
end
