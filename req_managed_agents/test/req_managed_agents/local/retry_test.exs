defmodule ReqManagedAgents.Local.RetryTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Local.Retry

  defp flaky(fails, reason, agent) do
    fn _request ->
      n = Agent.get_and_update(agent, &{&1, &1 + 1})
      if n < fails, do: {:error, reason}, else: {:ok, %{"ok" => n}}
    end
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    {:ok, agent: agent}
  end

  test "retries transient errors with exponential backoff", %{agent: agent} do
    test = self()
    cfg = %Retry{max_retries: 3, backoff_ms: 100, sleep_fun: &send(test, {:slept, &1})}

    wrapped = Retry.wrap(flaky(2, %{status: 503}, agent), cfg)
    assert {:ok, %{"ok" => 2}} = wrapped.(%{})
    assert_received {:slept, 100}
    assert_received {:slept, 200}
  end

  test "exhausted retries surface the error", %{agent: agent} do
    cfg = %Retry{max_retries: 1, backoff_ms: 1, sleep_fun: fn _ -> :ok end}
    wrapped = Retry.wrap(flaky(5, %{reason: :timeout}, agent), cfg)
    assert {:error, %{reason: :timeout}} = wrapped.(%{})
  end

  test "non-transient errors do not retry", %{agent: agent} do
    cfg = %Retry{max_retries: 3, backoff_ms: 1, sleep_fun: fn _ -> flunk("slept") end}
    wrapped = Retry.wrap(flaky(5, %{status: 401}, agent), cfg)
    assert {:error, %{status: 401}} = wrapped.(%{})
    assert Agent.get(agent, & &1) == 1
  end

  test "transient?/1 classification: 408/5xx + transport errors" do
    assert Retry.transient?(%{status: 408})
    assert Retry.transient?(%{status: 500})
    assert Retry.transient?(%{status: 503})
    refute Retry.transient?(%{status: 429})
    refute Retry.transient?(%{status: 404})
    assert Retry.transient?(%{reason: :timeout})
    assert Retry.transient?(%{reason: :econnrefused})
    assert Retry.transient?(%{cause: :closed})
    refute Retry.transient?(:weird)
  end
end
