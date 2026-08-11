defmodule ReqManagedAgents.Providers.BedrockAgentCoreDeadlineTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ReqManagedAgents.AgentCore.Client
  alias ReqManagedAgents.Providers.BedrockAgentCore, as: P
  alias ReqManagedAgents.Providers.BedrockAgentCore.WaitContext

  @creds %{
    access_key_id: "AKID",
    secret_access_key: "secret",
    region: "us-east-1",
    security_token: nil
  }

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
  # delete_fun is defaulted because every provision here ends in a failed
  # ready-wait, which fires rollback, and an un-injected rollback reaches a real
  # signed AWS endpoint. It REPORTS rather than absorbing: a stub that quietly
  # returns {:ok, %{}} suppresses exactly the rollback that bedrock_agent_core_test
  # asserts, so every timing test here would keep passing while the harness leaked.
  # Tests whose provision creates a harness assert {:deleted, hid}.
  #
  # Call this in the test process, never inside a spawned task — self() is captured
  # here, and a task-side call would send the report to the task.
  defp prov_opts(hid, extra) do
    test_pid = self()

    Keyword.merge(
      [
        execution_role_arn: "role",
        create_fun: created(hid),
        get_fun: always_creating(),
        delete_fun: fn id ->
          send(test_pid, {:deleted, id})
          {:ok, %{}}
        end
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

  # Exercises the REAL default poll closures — no get_fun/list_fun injected — so
  # the transport is reached through Client. An adapter stands in for the network
  # and reports the receive_timeout each request would have used.
  defp reporting_client(responder) do
    test_pid = self()

    adapter = fn req ->
      send(test_pid, {:request, req.method, req.url.path, req.options[:receive_timeout]})
      {req, responder.(req)}
    end

    Client.new(credentials: @creds, req_options: [adapter: adapter])
  end

  defp ok_json(body), do: %Req.Response{status: 200, body: body}

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
      opts = prov_opts("h-enclosed", timeout: 200)

      task = Task.async(fn -> provision_quietly(opts) end)

      assert {:error, {:harness_ready_timeout, %WaitContext{elapsed_ms: elapsed}}} =
               Task.await(task, caller_budget)

      assert elapsed < caller_budget
      assert_receive {:deleted, "h-enclosed"}
    end

    test "the named timeout error carries the status and poll count it actually observed" do
      assert {:error, {:harness_ready_timeout, %WaitContext{last_status: "CREATING", polls: p}}} =
               provision_quietly(prov_opts("h-named", timeout: 100, ready_poll_ms: 0))

      assert p > 0
      assert_receive {:deleted, "h-named"}
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

    test "a :timeout shorter than the default cadence still polls more than once" do
      # A 600 ms budget against the 5 s default interval used to buy exactly one
      # poll: create a harness, look once, roll it back, return in ~0 ms with the
      # budget arithmetic perfectly correct and nothing observed.
      assert {:error, {:harness_ready_timeout, %WaitContext{polls: p}}} =
               provision_quietly(prov_opts("h-subcadence", timeout: 600))

      assert p > 1
    end

    test "a provision that expires on the DEADLINE still rolls back what it created" do
      # Every legacy case expires on the poll count, because the derived deadline
      # is floored well above it — so nothing else in the suite reaches expiry
      # through the deadline itself. A restructure that skipped rollback on the
      # :timeout path would leave the rest of this file green.
      assert {:error, {:harness_ready_timeout, %WaitContext{}}} =
               provision_quietly(prov_opts("h-deadline-rollback", timeout: 100))

      assert_receive {:deleted, "h-deadline-rollback"}
    end

    test "a poll that fails on an exhausted budget is still named as a timeout" do
      # The last poll of a wait runs on whatever is left, so its receive timeout
      # can fall below real GetHarness latency and come back as a transport error.
      # Returned raw, that hands the caller a %Req.TransportError{} where the
      # deadline exists precisely to make the NAMED tag reachable.
      failing_get = fn _hid -> {:error, %Req.TransportError{reason: :timeout}} end

      assert {:error, {:harness_ready_timeout, %WaitContext{harness_id: "h-transport"}}} =
               provision_quietly(
                 prov_opts("h-transport", get_fun: failing_get, timeout: 0, ready_poll_ms: 0)
               )
    end

    test "a poll failure with budget still left is surfaced verbatim, not renamed" do
      # The rename applies only at exhaustion: a transport error with budget left
      # is a real provider error and must not be disguised as a timeout.
      failing_get = fn _hid -> {:error, %Req.TransportError{reason: :closed}} end

      assert {:error, %Req.TransportError{reason: :closed}} =
               provision_quietly(
                 prov_opts("h-transport-live", get_fun: failing_get, timeout: 60_000)
               )
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

      assert_receive {:deleted, "h-shared"}
    end
  end

  describe "the per-poll HTTP timeout is bounded by what is left of the budget" do
    test "a ready-poll may spend only its share of the remaining budget" do
      # The client's own receive_timeout is 600 s and a control-plane call retries
      # twice, so one hung poll could block ~30 minutes regardless of how short the
      # caller's budget was — which is what made the "360 s budget" not an upper
      # bound on anything.
      client = reporting_client(fn _req -> ok_json(%{"harness" => %{"status" => "READY"}}) end)

      assert {:ok, %{harness_id: "h-bounded"}} =
               provision_quietly(
                 execution_role_arn: "role",
                 create_fun: created("h-bounded"),
                 delete_fun: fn _hid -> {:ok, %{}} end,
                 client: client,
                 timeout: 30_000
               )

      assert_received {:request, :get, "/harnesses/h-bounded", receive_timeout}
      assert receive_timeout <= 10_000
      assert receive_timeout > 5_000
    end

    test "CreateHarness is bounded too — it runs with the budget fully intact" do
      # The exemption granted to rollback does not extend here: create runs before
      # any of the budget is spent, so "the budget for the whole call" is only true
      # if it is bounded. CreateHarness is a POST, which Req's :safe_transient
      # policy does not retry, so its share is the whole remaining budget rather
      # than a third of it.
      client =
        reporting_client(fn req ->
          case req.method do
            :post -> ok_json(%{"harness" => %{"arn" => "a", "harnessId" => "h-create"}})
            _ -> ok_json(%{"harness" => %{"status" => "READY"}})
          end
        end)

      assert {:ok, %{harness_id: "h-create"}} =
               provision_quietly(
                 execution_role_arn: "role",
                 delete_fun: fn _hid -> {:ok, %{}} end,
                 client: client,
                 timeout: 30_000
               )

      assert_received {:request, :post, "/harnesses", receive_timeout}
      assert receive_timeout <= 30_000
      assert receive_timeout > 25_000
    end

    test "a delete-wait listing is bounded the same way" do
      client = reporting_client(fn _req -> ok_json(%{"harnesses" => []}) end)

      assert {:error, {:harness_name_conflict, _name}} =
               provision_quietly(
                 execution_role_arn: "role",
                 create_fun: fn _spec -> {:error, {:http_error, 409, "exists"}} end,
                 delete_fun: fn _hid -> {:ok, %{}} end,
                 client: client,
                 timeout: 30_000
               )

      assert_received {:request, :get, "/harnesses", receive_timeout}
      assert receive_timeout <= 10_000
    end

    test "rollback gets a fixed budget of its own, neither derived nor unbounded" do
      # Two wrong answers here, and the test has to exclude both. Deriving the
      # bound from what is LEFT hands rollback ~1 ms and orphans the harness on
      # every timeout. Leaving it unbounded is the failure this release closes,
      # reproduced on the way out: 600 s across three attempts is ~30 minutes of
      # DELETE on a return path whose caller deadline has already passed, so the
      # enclosing timeout kills the process mid-DELETE and it leaks anyway.
      #
      # So: a fixed 30 s total, which is 10 s per attempt.
      client =
        reporting_client(fn req ->
          case req.method do
            :delete -> ok_json(%{})
            _ -> ok_json(%{"harness" => %{"status" => "CREATING"}})
          end
        end)

      assert {:error, {:harness_ready_timeout, %WaitContext{}}} =
               provision_quietly(
                 execution_role_arn: "role",
                 create_fun: created("h-rollback"),
                 client: client,
                 timeout: 50,
                 ready_poll_ms: 10
               )

      assert_received {:request, :delete, "/harnesses/h-rollback", receive_timeout}
      assert receive_timeout == 10_000
    end
  end

  describe "legacy poll opts" do
    test "a nonzero cadence still gets every poll the count allows" do
      # The zero-cadence cases below cannot see this: with poll_ms: 0 the derived
      # deadline collapses onto its floor and the count always binds first. At a
      # real cadence the derivation decides, and deriving only poll_ms * max_polls
      # ends the wait one poll early — the wait quietly shortens while every
      # assertion about it still passes.
      assert {:error, {:harness_ready_timeout, %WaitContext{polls: 4}}} =
               provision_quietly(prov_opts("h-cadence", ready_poll_ms: 5, ready_max_polls: 3))
    end

    test "still bound the wait by their count, unchanged" do
      # ready_poll_ms: 0 with ready_max_polls: 3 means "poll as fast as you can,
      # three times over" — attempts, not time. Reading that as a 0 ms wall-clock
      # budget would end the wait after a single poll.
      assert {:error, {:harness_ready_timeout, %WaitContext{polls: 4}}} =
               provision_quietly(prov_opts("h-legacy", ready_poll_ms: 0, ready_max_polls: 3))

      assert_receive {:deleted, "h-legacy"}
    end
  end
end
