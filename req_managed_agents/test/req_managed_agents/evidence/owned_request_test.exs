defmodule ReqManagedAgents.Evidence.OwnedRequestTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Evidence.OwnedRequest

  test "successful callbacks preserve arbitrary results and leave no mailbox residue" do
    for result <- [:value, {:error, :deadline}, {:error, :request_failed}] do
      assert OwnedRequest.run(fn -> result end, deadline()) == {:ok, result}
      assert Process.info(self(), :messages) == {:messages, []}
    end
  end

  test "worker crashes return a request failure and leave no mailbox residue" do
    assert OwnedRequest.run(fn -> exit(:kill) end, deadline()) == {:error, :request_failed}
    assert Process.info(self(), :messages) == {:messages, []}
  end

  test "deadline kills and reaps a blocked worker while its owner remains alive" do
    owner = self()

    assert OwnedRequest.run(
             fn ->
               send(owner, {:worker, self()})
               Process.sleep(:infinity)
             end,
             System.monotonic_time(:millisecond) + 50
           ) == {:error, :deadline}

    assert_received {:worker, worker}
    refute Process.alive?(worker)
    assert Process.info(self(), :messages) == {:messages, []}
  end

  test "Req.Test stubs follow the caller chain into the worker" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{ok: true}) end)

    assert {:ok, {:ok, %{body: %{"ok" => true}}}} =
             OwnedRequest.run(
               fn -> Req.get("https://example.test", plug: {Req.Test, __MODULE__}) end,
               deadline()
             )

    assert Process.info(self(), :messages) == {:messages, []}
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 1_000
end
