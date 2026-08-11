defmodule ReqManagedAgents.Providers.BedrockAgentCoreDeadlineTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ReqManagedAgents.Providers.BedrockAgentCore, as: P
  alias ReqManagedAgents.Providers.BedrockAgentCore.WaitContext

  @spec_bedrock %{
    name: "harness",
    system_prompt: "be helpful",
    tools: [%{"name" => "t"}],
    terminal_tool: nil,
    model_config: %{"bedrockModelConfig" => %{"modelId" => "anthropic.claude-sonnet-4"}}
  }

  # A harness that never leaves CREATING: the ready-wait can then only end on its
  # own budget, which is what every assertion in this file is about.
  defp always_creating, do: fn _hid -> {:ok, %{"harness" => %{"status" => "CREATING"}}} end

  defp created(hid),
    do: fn _spec -> {:ok, %{"harness" => %{"arn" => "a", "harnessId" => hid}}} end

  # `extra` wins: a keyword list resolves left-to-right, so appending the overrides
  # would leave them shadowed by the defaults and silently test the wrong path.
  #
  # delete_fun is defaulted for the reason recorded in bedrock_agent_core_test.exs:
  # every provision here ends in a failed ready-wait, which fires rollback, and an
  # un-injected rollback reaches a real signed AWS endpoint.
  defp prov_opts(hid, extra) do
    Keyword.merge(
      [
        execution_role_arn: "role",
        create_fun: created(hid),
        get_fun: always_creating(),
        delete_fun: fn _hid -> {:ok, %{}} end
      ],
      extra
    )
  end

  # Every poll writes a Logger.debug line, and against an in-memory stub that
  # console write costs orders of magnitude more than the poll itself — enough to
  # dominate any wall-clock assertion. Capturing keeps these measurements about
  # the library's budget rather than the console's throughput.
  defp provision_quietly(opts) do
    {result, _log} = with_log(fn -> P.provision(@spec_bedrock, opts) end)
    result
  end

  describe "the caller's deadline bounds the waits" do
    test "a provision returns its named error well inside an enclosing caller's budget" do
      # This is the 07-30 failure, in miniature. provision consumed the caller's
      # clock — 72 polls at a 5 s cadence, un-budgeted by anything above it — so
      # the enclosing timeout fired FIRST and the run died as an anonymous kill
      # with no named error anywhere in the log. Here the enclosing budget is 600
      # ms and provision is given 200: the named error has to arrive first.
      #
      # A failure surfaces as a Task.await timeout, which is exactly the shape the
      # canary failed in.
      caller_budget = 600

      task =
        Task.async(fn ->
          provision_quietly(prov_opts("h-enclosed", timeout: 200, ready_poll_ms: 50))
        end)

      assert {:error, {:harness_ready_timeout, %WaitContext{elapsed_ms: elapsed}}} =
               Task.await(task, caller_budget)

      assert elapsed < caller_budget
    end

    test "the named timeout error carries the status and poll count it actually observed" do
      assert {:error, {:harness_ready_timeout, %WaitContext{last_status: "CREATING", polls: p}}} =
               provision_quietly(prov_opts("h-named", timeout: 100, ready_poll_ms: 0))

      assert p > 0
    end

    test "an explicit :timeout drops the legacy poll count rather than being capped by it" do
      # :timeout and :ready_max_polls are two expressions of one budget. The new
      # one is purely time-based, so a caller who asks for 100 ms must get 100 ms
      # of polling and must not stop after the 2 polls the legacy opt describes.
      assert {:error, {:harness_ready_timeout, %WaitContext{polls: p}}} =
               provision_quietly(
                 prov_opts("h-uncapped", timeout: 100, ready_poll_ms: 0, ready_max_polls: 2)
               )

      assert p > 100
    end

    test "a :timeout that is not a non-negative integer is rejected, not silently ignored" do
      assert {:error, {:invalid_opts, :timeout}} =
               P.provision(@spec_bedrock, prov_opts("h-invalid", timeout: -1))

      assert {:error, {:invalid_opts, :timeout}} =
               P.provision(@spec_bedrock, prov_opts("h-invalid", timeout: :infinity))
    end
  end

  describe "the delete-wait and the ready-wait share one deadline" do
    test "a recover-delete-recreate provision spends one budget across both waits" do
      # Before, each wait got its own full budget, so one provision could spend up
      # to twice what its caller allowed. The delete-wait here burns half of a 300
      # ms budget before the harness disappears; the ready-wait must then inherit
      # what is LEFT rather than starting a fresh one.
      #
      # The delete phase is driven by the clock rather than by a poll count so it
      # measures a fixed 150 ms regardless of how fast the machine polls.
      name = P.harness_name(@spec_bedrock, nil)
      gone_at = System.monotonic_time(:millisecond) + 150

      list_fun = fn ->
        harnesses =
          if System.monotonic_time(:millisecond) >= gone_at,
            do: [],
            else: [%{"harnessName" => name, "status" => "DELETING"}]

        {:ok, %{"harnesses" => harnesses}}
      end

      {:ok, creates} = Agent.start_link(fn -> 0 end)

      create_fun = fn _spec ->
        case Agent.get_and_update(creates, &{&1 + 1, &1 + 1}) do
          1 -> {:error, {:http_error, 409, "exists"}}
          _ -> {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "h-shared"}}}
        end
      end

      started = System.monotonic_time(:millisecond)

      assert {:error,
              {:harness_ready_timeout,
               %WaitContext{harness_id: "h-shared", elapsed_ms: ready_elapsed}}} =
               provision_quietly(
                 prov_opts("h-shared",
                   create_fun: create_fun,
                   list_fun: list_fun,
                   timeout: 300,
                   ready_poll_ms: 0
                 )
               )

      # The ready-wait got the REMAINDER of the budget. A budget of its own would
      # have run it the full 300 ms.
      assert ready_elapsed < 250

      # And the whole provision stayed inside one budget: two would be the 150 ms
      # delete-wait plus a fresh 300 ms ready-wait.
      assert System.monotonic_time(:millisecond) - started < 400
    end
  end

  describe "legacy poll opts" do
    test "still bound the wait by their count, unchanged" do
      # ready_poll_ms: 0 with ready_max_polls: 3 means "poll as fast as you can,
      # three times over" — attempts, not time. Reading that as a 0 ms wall-clock
      # budget would end the wait after a single poll.
      assert {:error, {:harness_ready_timeout, %WaitContext{polls: 4}}} =
               provision_quietly(prov_opts("h-legacy", ready_poll_ms: 0, ready_max_polls: 3))
    end
  end
end
