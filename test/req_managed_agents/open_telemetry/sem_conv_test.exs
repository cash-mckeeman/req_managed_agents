defmodule ReqManagedAgents.OpenTelemetry.SemConvTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.OpenTelemetry.SemConv

  test "provider_name is anthropic for the managed-agents path" do
    assert SemConv.provider_name() == "anthropic"
  end

  test "finish_reason maps terminal atoms to spec strings" do
    assert SemConv.finish_reason(:end_turn) == "end_turn"
    assert SemConv.finish_reason(:terminated) == "terminated"
    assert SemConv.finish_reason(:error) == "error"
    assert SemConv.finish_reason(:retries_exhausted) == "retries_exhausted"
    assert SemConv.finish_reason(:anything_else) == "terminated"
  end
end
