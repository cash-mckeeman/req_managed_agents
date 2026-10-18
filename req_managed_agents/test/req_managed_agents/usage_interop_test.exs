defmodule ReqManagedAgents.UsageInteropTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Test.ExecutionUsageFixture

  test "actual producer usage renders measured counts, coverage and input basis to JSON" do
    samples = ExecutionUsageFixture.samples() |> Jason.encode!() |> Jason.decode!()

    for name <- ["local-inclusive", "local-uncached", "cma-request", "agentcore-turn"] do
      usage = Map.fetch!(samples, name)
      assert usage["input_tokens"] == 12
      assert usage["output_tokens"] == 4
      assert usage["cache_read_input_tokens"] == 3
      assert usage["cache_creation_input_tokens"] == 2

      assert usage["input_token_basis"] ==
               if(name == "local-inclusive", do: "inclusive", else: "uncached")

      assert usage["complete?"] == true
    end

    assert samples["local-zero"]["cache_read_input_tokens"] == 0
    assert samples["local-zero"]["cache_creation_input_tokens"] == 0
    assert samples["local-zero"]["complete?"] == true

    for name <- ["local-missing", "local-mixed", "req-llm-ambiguous-zero"] do
      usage = samples[name]
      assert Map.has_key?(usage, "cache_read_input_tokens")
      assert usage["cache_read_input_tokens"] == nil
      assert usage["cache_creation_input_tokens"] == nil
      assert usage["complete?"] == false
    end

    assert samples["local-mixed"]["input_tokens"] == 12
    assert samples["local-mixed"]["output_tokens"] == 4
    assert samples["local-mixed"]["input_token_basis"] == "unknown"
    assert samples["req-llm-ambiguous-zero"]["input_token_basis"] == "unknown"
  end

  test "frozen consumer fixture matches actual serialized producer output" do
    actual = ExecutionUsageFixture.samples() |> Jason.encode!() |> Jason.decode!()
    path = Path.join([__DIR__, "..", "support", "fixtures", "execution_usage", "usage.json"])
    assert actual == path |> File.read!() |> Jason.decode!()
  end
end
