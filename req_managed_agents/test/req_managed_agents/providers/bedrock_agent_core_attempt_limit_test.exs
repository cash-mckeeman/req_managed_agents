defmodule ReqManagedAgents.Providers.BedrockAgentCoreAttemptLimitTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Providers.BedrockAgentCore, as: P

  defp done, do: {:ok, [%{"messageStop" => %{"stopReason" => "end_turn"}}]}

  defp transport(responses) do
    script = start_supervised!({Agent, fn -> {0, responses} end})
    owner = self()

    fun = fn _ ->
      {ordinal, response} =
        Agent.get_and_update(script, fn {n, [response | rest]} ->
          {{n + 1, response}, {n + 1, rest}}
        end)

      send(owner, {:invoked, ordinal, self()})
      response
    end

    {fun, script}
  end

  defp open(fun, opts) do
    P.open(
      Keyword.merge(
        [harness_arn: "arn:new", runtime_session_id: String.duplicate("s", 33), invoke_fun: fun],
        opts
      ),
      nil
    )
  end

  test "invalid cap is refused before constructing a credentialed client" do
    for limit <- [0, -1, 2.5, "1", true, false, :invalid, []] do
      assert P.open(
               [
                 harness_arn: "arn:new",
                 runtime_session_id: String.duplicate("s", 33),
                 max_invocation_attempts: limit
               ],
               nil
             ) ==
               {:error, {:invalid_opts, :max_invocation_attempts}}
    end
  end

  test "truncated retries cannot exceed one admitted call" do
    {fun, script} = transport([{:ok, []}, done(), done(), done()])
    {:ok, conn} = open(fun, max_invocation_attempts: 1, invoke_retries: 3)
    assert P.poll_turn(conn, []) == {:error, {:max_invocation_attempts_exceeded, 1}}
    assert {1, _} = Agent.get(script, & &1)
    assert_receive {:invoked, 1, _}
    refute_receive {:invoked, 2, _}
  end

  test "transport and truncated retries consume the same cap" do
    {fun, script} = transport([{:error, :closed}, {:ok, []}, done(), done()])
    {:ok, conn} = open(fun, max_invocation_attempts: 2, invoke_retries: 3)
    assert P.poll_turn(conn, []) == {:error, {:max_invocation_attempts_exceeded, 2}}
    assert {2, _} = Agent.get(script, & &1)
    assert_receive {:invoked, 1, _}
    assert_receive {:invoked, 2, _}
  end

  test "successful turns do not reset the cap" do
    {fun, script} = transport([{:ok, []}, done(), done()])
    {:ok, conn} = open(fun, max_invocation_attempts: 2, invoke_retries: 3)
    assert {:ok, _, returned} = P.poll_turn(conn, [])
    assert P.poll_turn(returned, []) == {:error, {:max_invocation_attempts_exceeded, 2}}
    assert {2, _} = Agent.get(script, & &1)
  end

  test "retry exhaustion preserves the original error below the cap" do
    {fun, script} = transport([{:error, :closed}])
    {:ok, conn} = open(fun, max_invocation_attempts: 5, invoke_retries: 0)
    assert P.poll_turn(conn, []) == {:error, :closed}
    assert {1, []} = Agent.get(script, & &1)
  end

  test "a failed poll in another task still consumes the original connection gate" do
    {fun, script} = transport([{:error, :closed}, done()])
    {:ok, conn} = open(fun, max_invocation_attempts: 1, invoke_retries: 0)
    first = Task.async(fn -> P.poll_turn(conn, []) end)
    assert Task.await(first) == {:error, :closed}
    second = Task.async(fn -> P.poll_turn(conn, []) end)
    refute first.pid == second.pid
    assert Task.await(second) == {:error, {:max_invocation_attempts_exceeded, 1}}
    assert {1, _} = Agent.get(script, & &1)
    assert_receive {:invoked, 1, pid}
    assert pid == first.pid
  end

  test "independent opens sharing the remote session ID have fresh caps" do
    {fun, script} = transport([done(), done()])
    {:ok, first} = open(fun, max_invocation_attempts: 1)
    {:ok, second} = open(fun, max_invocation_attempts: 1)
    assert {:ok, _, _} = P.poll_turn(first, [])
    assert {:ok, _, _} = P.poll_turn(second, [])
    assert {2, []} = Agent.get(script, & &1)
  end

  test "exceptions throws and exits consume admission without changing their behavior" do
    for {kind, fun} <- [
          raise: fn _ -> raise "transport failed" end,
          throw: fn _ -> throw(:thrown) end,
          exit: fn _ -> exit(:gone) end
        ] do
      {:ok, conn} = open(fun, max_invocation_attempts: 1)

      case kind do
        :raise -> assert_raise RuntimeError, "transport failed", fn -> P.poll_turn(conn, []) end
        :throw -> assert catch_throw(P.poll_turn(conn, [])) == :thrown
        :exit -> assert catch_exit(P.poll_turn(conn, [])) == :gone
      end

      assert P.poll_turn(conn, []) == {:error, {:max_invocation_attempts_exceeded, 1}}
    end
  end

  test "nil and omitted caps preserve retries and subsequent polls" do
    for opts <- [[], [max_invocation_attempts: nil]] do
      {fun, script} = transport([{:ok, []}, done(), done()])
      {:ok, conn} = open(fun, opts)
      assert {:ok, _, returned} = P.poll_turn(conn, [])
      assert {:ok, _, _} = P.poll_turn(returned, [])
      assert {3, []} = Agent.get(script, & &1)
      stop_supervised!(Agent)
    end
  end
end
