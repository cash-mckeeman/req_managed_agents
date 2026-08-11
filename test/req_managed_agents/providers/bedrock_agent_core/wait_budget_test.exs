defmodule ReqManagedAgents.Providers.BedrockAgentCore.WaitBudgetTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Providers.BedrockAgentCore.WaitBudget

  describe "new/1" do
    test "an explicit :timeout becomes the whole budget" do
      assert {:ok, budget} = WaitBudget.new(timeout: 5_000)
      assert WaitBudget.remaining(budget) > 4_000
      assert WaitBudget.remaining(budget) <= 5_000
    end

    test "an explicit :timeout drops the legacy poll count, so it cannot cap the caller" do
      # 72 polls * 5 s describes 360 s; a caller asking for 600 s must get 600 s,
      # not be cut off at whatever the legacy default count happens to describe.
      assert {:ok, budget} = WaitBudget.new(timeout: 600_000)
      assert budget.polls_left == :infinity
    end

    test "the default budget is the wall-clock the default poll opts describe" do
      assert {:ok, budget} = WaitBudget.new([])
      assert budget.poll_ms == 5_000
      assert budget.polls_left == 72
      assert WaitBudget.remaining(budget) > 359_000
    end

    test "legacy poll opts keep their count and are floored at the default deadline" do
      # `ready_poll_ms: 0` means "poll as fast as you can, N times" — attempts,
      # not time. Deriving 0 * N as a wall-clock budget would end the wait after
      # a single poll, so the derived deadline is floored.
      assert {:ok, budget} = WaitBudget.new(ready_poll_ms: 0, ready_max_polls: 3)
      assert budget.polls_left == 3
      assert WaitBudget.remaining(budget) > 359_000
    end

    test "a legacy poll budget longer than the default deadline is honoured, not capped" do
      assert {:ok, budget} = WaitBudget.new(ready_poll_ms: 10_000, ready_max_polls: 100)
      assert WaitBudget.remaining(budget) > 999_000
    end

    test "a non-integer or negative :timeout is rejected rather than silently ignored" do
      assert {:error, {:invalid_opts, :timeout}} = WaitBudget.new(timeout: -1)
      assert {:error, {:invalid_opts, :timeout}} = WaitBudget.new(timeout: "300")
      assert {:error, {:invalid_opts, :timeout}} = WaitBudget.new(timeout: :infinity)
    end
  end

  describe "next/1" do
    test "a budget with room to sleep again polls again" do
      {:ok, budget} = WaitBudget.new(timeout: 60_000, ready_poll_ms: 10)
      assert WaitBudget.next(budget) == :poll
    end

    test "a budget too short for one more full sleep is expired, not merely over" do
      # The invariant: a wait stops while it still has time to RETURN. Sleeping a
      # full poll interval that does not fit is what pushed a provision past the
      # deadline of the caller it ran under.
      {:ok, budget} = WaitBudget.new(timeout: 5, ready_poll_ms: 5_000)
      assert WaitBudget.next(budget) == :expired
    end

    test "an exhausted legacy poll count expires the budget even with time left" do
      {:ok, budget} = WaitBudget.new(ready_poll_ms: 0, ready_max_polls: 1)
      assert WaitBudget.next(budget) == :poll

      spent = WaitBudget.spend(budget)
      assert WaitBudget.next(spent) == :expired
      assert WaitBudget.remaining(spent) > 359_000
    end

    test "an infinite poll count never expires on count alone" do
      {:ok, budget} = WaitBudget.new(timeout: 60_000, ready_poll_ms: 0)

      spent =
        Enum.reduce(1..50, budget, fn _, acc -> WaitBudget.spend(acc) end)

      assert spent.polls_left == :infinity
      assert WaitBudget.next(spent) == :poll
    end
  end

  describe "attempt_timeout/3" do
    test "one attempt may spend only its share of what is left" do
      {:ok, budget} = WaitBudget.new(timeout: 30_000)
      assert WaitBudget.attempt_timeout(budget, 600_000, 3) in 9_000..10_000
    end

    test "the configured timeout still wins when it is the smaller of the two" do
      {:ok, budget} = WaitBudget.new(timeout: 600_000)
      assert WaitBudget.attempt_timeout(budget, 3_000, 3) == 1_000
    end

    test "an unbounded configured timeout is bounded by the budget alone" do
      {:ok, budget} = WaitBudget.new(timeout: 30_000)
      assert WaitBudget.attempt_timeout(budget, :infinity, 3) in 9_000..10_000
    end

    test "a spent budget still yields a positive timeout rather than zero or negative" do
      # Req rejects a non-positive receive_timeout; a spent budget must degrade to
      # "try once, briefly", never to a crash on the way out.
      {:ok, budget} = WaitBudget.new(timeout: 0)
      assert WaitBudget.attempt_timeout(budget, 600_000, 3) == 1
    end
  end
end
