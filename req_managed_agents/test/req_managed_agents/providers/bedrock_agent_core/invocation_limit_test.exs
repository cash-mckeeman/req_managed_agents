defmodule ReqManagedAgents.Providers.BedrockAgentCore.InvocationLimitTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Providers.BedrockAgentCore.InvocationLimit

  test "nil disables admission without a counter" do
    assert InvocationLimit.new(nil) == {:ok, nil}
    assert InvocationLimit.take(nil) == :ok
  end

  test "invalid limits return the option error" do
    for limit <- [0, -1, 1.5, "2", true, false, :unlimited, [], %{}] do
      assert InvocationLimit.new(limit) == {:error, {:invalid_opts, :max_invocation_attempts}}
    end
  end

  test "a finite limit repeatedly refuses after exactly its admitted count" do
    assert {:ok, gate} = InvocationLimit.new(2)
    assert InvocationLimit.take(gate) == :ok
    assert InvocationLimit.take(gate) == :ok

    for _ <- 1..10 do
      assert InvocationLimit.take(gate) == {:error, {:max_invocation_attempts_exceeded, 2}}
    end
  end

  test "concurrent tasks share one admission count" do
    {:ok, gate} = InvocationLimit.new(2)

    results =
      1..50
      |> Task.async_stream(fn _ -> InvocationLimit.take(gate) end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.frequencies(results) == %{
             :ok => 2,
             {:error, {:max_invocation_attempts_exceeded, 2}} => 48
           }
  end
end
