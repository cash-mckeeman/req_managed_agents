defmodule ReqManagedAgents.Artifacts.AgentCoreSessionStorageTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.AgentCore.CommandResult
  alias ReqManagedAgents.Artifact
  alias ReqManagedAgents.Artifacts
  alias ReqManagedAgents.Artifacts.AgentCoreSessionStorage, as: Storage

  defp store(command_fun) do
    {Storage,
     Storage.store(
       :fake_client,
       "arn:aws:bedrock-agentcore:us-east-1:1:runtime/x",
       String.duplicate("s", 33),
       "/mnt/data",
       command_fun: command_fun
     )}
  end

  test "list runs a python scandir and maps its JSON to Artifacts" do
    test_pid = self()

    fun = fn inv ->
      send(test_pid, {:cmd, inv.command})

      {:ok,
       %CommandResult{
         stdout: ~s([{"name":"report.md","size":42},{"name":"data.csv","size":7}]),
         exit_code: 0
       }}
    end

    assert {:ok,
            [
              %Artifact{name: "report.md", size: 42, ref: "/mnt/data/report.md"},
              %Artifact{name: "data.csv", size: 7, ref: "/mnt/data/data.csv"}
            ]} = Artifacts.list(store(fun))

    assert_received {:cmd, cmd}
    assert cmd =~ "python3 -c"
    assert cmd =~ "'/mnt/data'"
  end

  test "fetch base64-decodes stdout; exit 3 maps to :not_found" do
    fun = fn inv ->
      assert inv.command =~ "'/mnt/data/report.md'"
      {:ok, %CommandResult{stdout: Base.encode64(<<0, 255, "binary!">>), exit_code: 0}}
    end

    assert {:ok, <<0, 255, "binary!">>} = Artifacts.fetch(store(fun), "report.md")

    missing = fn _inv -> {:ok, %CommandResult{stderr: "", exit_code: 3}} end
    assert {:error, :not_found} = Artifacts.fetch(store(missing), "report.md")
  end

  test "put chunks base64 appends within the 64KB command cap, then decodes into place" do
    test_pid = self()
    counter = :counters.new(1, [])

    fun = fn inv ->
      :counters.add(counter, 1, 1)
      send(test_pid, {:cmd, :counters.get(counter, 1), inv.command})
      {:ok, %CommandResult{exit_code: 0}}
    end

    # ~100KB of contents -> base64 ~136k chars -> 3 append commands + 1 decode command.
    contents = :crypto.strong_rand_bytes(100_000)
    assert :ok = Artifacts.put(store(fun), "big.bin", contents)

    assert :counters.get(counter, 1) == 4
    assert_received {:cmd, 1, c1}
    assert String.length(c1) <= 65_536
    assert_received {:cmd, 4, c4}
    assert c4 =~ "base64" or c4 =~ "b64decode"
  end

  test "delete: ok, not_found, and command_failed carry the CommandResult" do
    ok_fun = fn _ -> {:ok, %CommandResult{exit_code: 0}} end
    assert :ok = Artifacts.delete(store(ok_fun), "report.md")

    nf = fn _ -> {:ok, %CommandResult{exit_code: 3}} end
    assert {:error, :not_found} = Artifacts.delete(store(nf), "report.md")

    boom = fn _ -> {:ok, %CommandResult{stderr: "denied", exit_code: 1}} end

    assert {:error, {:command_failed, %CommandResult{stderr: "denied", exit_code: 1}}} =
             Artifacts.delete(store(boom), "report.md")
  end

  test "names outside the safe charset are rejected before any command runs" do
    fun = fn _ -> flunk("no command should run") end

    assert {:error, {:invalid_name, "../etc/passwd"}} =
             Artifacts.fetch(store(fun), "../etc/passwd")

    assert {:error, {:invalid_name, "a'b"}} = Artifacts.delete(store(fun), "a'b")
  end

  test "store/5 raises on a base_path containing a single quote" do
    assert_raise ArgumentError, ~r/base_path must not contain single quotes/, fn ->
      Storage.store(
        :c,
        "arn:aws:bedrock-agentcore:us-east-1:1:runtime/x",
        String.duplicate("s", 33),
        "/mnt/user's-data"
      )
    end
  end

  test "transport errors pass through" do
    fun = fn _ -> {:error, :timeout} end
    assert {:error, :timeout} = Artifacts.list(store(fun))
  end
end
