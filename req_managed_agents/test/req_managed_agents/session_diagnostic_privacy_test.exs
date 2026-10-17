defmodule ReqManagedAgents.SessionDiagnosticPrivacyTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  require Logger

  alias ReqManagedAgents.Providers.BedrockAgentCore
  alias ReqManagedAgents.Session

  @prompt "private-prompt-sentinel"
  @harness "private-harness-sentinel"
  @runtime "private-runtime-session-sentinel"
  @reason "private-native-reason-sentinel"

  test "unexpected session failure preserves caller error but redacts real Logger diagnostics" do
    log =
      capture_log(fn ->
        result =
          Session.run(
            BedrockAgentCore,
            options(
              invoke_fun: fn _ -> {:ok, [%{"messageStop" => %{"stopReason" => "end_turn"}}]} end,
              turn_guard: fn _ -> raise @reason end
            )
          )

        assert {:error, {%RuntimeError{message: @reason}, stack}} = result
        assert is_list(stack) and stack != []
        Logger.warning("ordinary-diagnostic-control")
      end)

    assert log =~ "terminating"
    assert log =~ "ordinary-diagnostic-control"
    for sentinel <- [@prompt, @harness, @runtime, @reason], do: refute(log =~ sentinel)
  end

  test "argument-bearing callback failure does not expose native identities through stack frames" do
    log =
      capture_log(fn ->
        result =
          Session.run(
            BedrockAgentCore,
            options(
              invoke_fun: fn _ -> {:ok, [%{"messageStop" => %{"stopReason" => "end_turn"}}]} end,
              turn_guard: fn :impossible -> :cont end
            )
          )

        assert {:error, {:function_clause, stack}} = result
        assert is_list(stack) and stack != []
      end)

    assert log =~ "terminating"
    for sentinel <- [@prompt, @harness, @runtime], do: refute(log =~ sentinel)
  end

  test "unexpected poll task exits and throws retain caller reasons without leaking diagnostics" do
    owner = self()

    for kind <- [:exit, :throw] do
      log =
        capture_log(fn ->
          invoke = fn _ ->
            send(owner, {:poll_invoked, self()})

            case kind do
              :exit -> exit(@reason)
              :throw -> throw(@reason)
            end
          end

          result = Session.run(BedrockAgentCore, options(invoke_fun: invoke))

          case kind do
            :exit ->
              assert {:error, @reason} = result

            :throw ->
              assert {:error, {{:nocatch, @reason}, stack}} = result
              assert is_list(stack) and stack != []
          end
        end)

      assert log =~ "terminating"
      assert_receive {:poll_invoked, task}
      refute Process.alive?(task)
      refute_receive {:poll_invoked, _}
      for sentinel <- [@prompt, @harness, @runtime, @reason], do: refute(log =~ sentinel)
    end
  end

  test "normal poll task exit remains pending until the existing synchronous timeout" do
    result =
      Session.run(BedrockAgentCore, options(timeout: 25, invoke_fun: fn _ -> exit(:normal) end))

    assert result == {:error, :timeout}
  end

  test "status redaction and untracked failure messages leave the active session intact" do
    owner = self()

    {:ok, session} =
      Session.start_link(
        BedrockAgentCore,
        options(
          invoke_fun: fn _ ->
            send(owner, {:blocked_poll, self()})
            receive do: (:release -> {:ok, []})
          end
        )
      )

    assert_receive {:blocked_poll, task}
    send(session, {:poll_task_failed, self(), @reason})
    send(session, {:poll_task_failed, nil, @reason})
    assert {:error, :unsupported} = GenServer.call(session, {:send_event, %{}})
    status = session |> :sys.get_status() |> inspect()
    assert status =~ "redacted"
    assert status =~ "ReqManagedAgents.Session"
    for sentinel <- [@prompt, @harness, @runtime], do: refute(status =~ sentinel)
    assert Process.alive?(session)
    GenServer.stop(session)
    refute Process.alive?(task)
  end

  defp options(overrides) do
    Keyword.merge(
      [
        handler: fn _, _, _ -> {:ok, "ok"} end,
        prompt: @prompt,
        harness_arn: @harness,
        runtime_session_id: @runtime,
        invoke_retries: 0,
        timeout: 1000
      ],
      overrides
    )
  end
end
