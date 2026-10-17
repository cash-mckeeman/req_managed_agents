defmodule ReqManagedAgents.SessionAgentCoreAttemptLimitTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Evidence.{Options, Recorder}
  alias ReqManagedAgents.Providers.BedrockAgentCore, as: P
  alias ReqManagedAgents.{Session, SessionResult}

  defp done, do: {:ok, [%{"messageStop" => %{"stopReason" => "end_turn"}}]}

  defp tool_turn do
    {:ok,
     [
       %{
         "contentBlockStart" => %{
           "contentBlockIndex" => 0,
           "start" => %{"toolUse" => %{"toolUseId" => "t1", "name" => "echo"}}
         }
       },
       %{
         "contentBlockDelta" => %{
           "contentBlockIndex" => 0,
           "delta" => %{"toolUse" => %{"input" => "{}"}}
         }
       },
       %{"messageStop" => %{"stopReason" => "tool_use"}}
     ]}
  end

  defp script(responses) do
    agent = start_supervised!({Agent, fn -> {0, responses} end}, id: make_ref())
    owner = self()

    fun = fn inv ->
      {n, response} =
        Agent.get_and_update(agent, fn {n, [head | tail]} -> {{n + 1, head}, {n + 1, tail}} end)

      send(owner, {:invoked, n, self(), inv.messages})
      response
    end

    {agent, fun}
  end

  defp opts(fun, cap) do
    owner = self()

    [
      harness_arn: "arn:new",
      runtime_session_id: String.duplicate("s", 33),
      invoke_fun: fun,
      max_invocation_attempts: cap,
      max_turns: 10,
      invoke_retries: 3,
      handler: fn "echo", %{}, _ ->
        send(owner, :handled)
        {:ok, "tool result"}
      end
    ]
  end

  test "retries and tool continuations share one cap across poll tasks" do
    {agent, fun} = script([{:ok, []}, tool_turn(), done()])
    assert Session.run(P, opts(fun, 2)) == {:error, {:max_invocation_attempts_exceeded, 2}}
    assert {2, _} = Agent.get(agent, & &1)
    assert_receive :handled
    refute_receive :handled
    assert_receive {:invoked, 1, first, _}
    assert_receive {:invoked, 2, ^first, _}
    refute_receive {:invoked, 3, _, _}
  end

  test "a third admitted invocation completes the tool continuation in a new task" do
    {agent, fun} = script([{:ok, []}, tool_turn(), done()])
    assert {:ok, %SessionResult{terminal: :end_turn, turns: 2}} = Session.run(P, opts(fun, 3))
    assert {3, []} = Agent.get(agent, & &1)
    assert_receive :handled
    refute_receive :handled
    assert_receive {:invoked, 1, first, _}
    assert_receive {:invoked, 2, ^first, _}
    assert_receive {:invoked, 3, second, messages}
    refute first == second

    assert [
             %{"role" => "assistant"},
             %{"role" => "user", "content" => [%{"toolResult" => %{"toolUseId" => "t1"}}]}
           ] = messages
  end

  test "live messages keep the cap while a separate run with the same AWS ID starts fresh" do
    {agent, fun} = script([done(), done(), done()])
    {:ok, session} = Session.start_link(P, opts(fun, 1) ++ [notify: self()])
    monitor = Process.monitor(session)
    assert_receive {:managed_agents_session, %SessionResult{terminal: :end_turn}}, 2000
    assert_receive {:invoked, 1, _, _}
    Session.message(session, "second")
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 2000
    assert {1, _} = Agent.get(agent, & &1)
    assert {:ok, %SessionResult{terminal: :end_turn}} = Session.run(P, opts(fun, 1))
    assert {2, _} = Agent.get(agent, & &1)
  end

  test "evidence records only admitted work and a distinct invocation refusal" do
    {:ok, options} = Options.new([])
    recorder = start_supervised!({Recorder, options})
    {agent, fun} = script([{:ok, []}, done()])

    assert Session.run(P, opts(fun, 1) ++ [evidence_recorder: recorder]) ==
             {:error, {:max_invocation_attempts_exceeded, 1}}

    assert {1, _} = Agent.get(agent, & &1)
    assert {:ok, capture} = Recorder.snapshot(recorder)
    local = Enum.filter(capture.records, &(&1.kind == :local))
    assert [_ | _] = local
    starts = Enum.filter(local, &(&1.payload.type == :attempt_started))
    assert [%{attempt_id: attempt_id}] = starts
    assert is_binary(attempt_id)

    assert [%{payload: %{error_code: "max_invocation_attempts_exceeded", result: :error}}] =
             Enum.filter(local, &(&1.payload.type == :invocation_finished))

    assert [] == Enum.filter(local, &(&1.payload.type == :retry_decided))

    assert [%{attempt_id: ^attempt_id, payload: %{error_code: "early_termination"}}] =
             Enum.filter(local, &(&1.payload.type == :transport_failed))
  end
end
