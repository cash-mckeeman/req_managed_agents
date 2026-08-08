defmodule ReqManagedAgents.Providers.BedrockAgentCore.HarnessStatusTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Providers.BedrockAgentCore, as: P
  alias ReqManagedAgents.Providers.BedrockAgentCore.HarnessStatus
  alias ReqManagedAgents.Providers.BedrockAgentCore.WaitContext

  @spec_bedrock %{
    name: "harness",
    system_prompt: "be helpful",
    tools: [],
    terminal_tool: nil,
    model_config: %{"m" => 1}
  }

  test "classifies the known vocabulary" do
    assert HarnessStatus.classify("READY") == :ready
    assert HarnessStatus.classify("CREATING") == :creating
    assert HarnessStatus.classify("UPDATING") == :creating
    assert HarnessStatus.classify("DELETING") == :terminating
    assert HarnessStatus.classify("CREATE_FAILED") == {:failed, "CREATE_FAILED"}
    assert HarnessStatus.classify("UPDATE_FAILED") == {:failed, "UPDATE_FAILED"}
    assert HarnessStatus.classify("DELETE_FAILED") == {:failed, "DELETE_FAILED"}
  end

  test "an unrecognized status is named, not silently polled" do
    assert HarnessStatus.classify("INACTIVE") == {:unknown, "INACTIVE"}
  end

  test "the classification covers every status the service model declares" do
    # The service model's HarnessStatus enum is closed; anything outside it is a
    # genuinely new status and must surface as {:unknown, s} rather than a poll.
    declared = ~w(CREATING CREATE_FAILED UPDATING UPDATE_FAILED READY DELETING DELETE_FAILED)

    for status <- declared do
      refute match?({:unknown, _}, HarnessStatus.classify(status)),
             "#{status} is declared by the service model but classifies as unknown"
    end
  end

  test "a DELETING harness terminates the ready-wait instead of polling it" do
    create = fn _ -> {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "h"}}} end
    get_fun = fn _hid -> {:ok, %{"harness" => %{"status" => "DELETING"}}} end

    assert {:error, {:harness_terminating, %WaitContext{last_status: "DELETING"}}} =
             P.provision(@spec_bedrock,
               execution_role_arn: "role",
               create_fun: create,
               get_fun: get_fun,
               delete_fun: fn _ -> {:ok, %{}} end,
               ready_poll_ms: 0,
               ready_max_polls: 3
             )
  end

  test "an unknown status terminates the ready-wait instead of burning the budget" do
    create = fn _ -> {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "h"}}} end
    get_fun = fn _hid -> {:ok, %{"harness" => %{"status" => "INACTIVE"}}} end

    assert {:error, {:harness_unknown_status, %WaitContext{last_status: "INACTIVE"}}} =
             P.provision(@spec_bedrock,
               execution_role_arn: "role",
               create_fun: create,
               get_fun: get_fun,
               delete_fun: fn _ -> {:ok, %{}} end,
               ready_poll_ms: 0,
               ready_max_polls: 3
             )
  end

  test "a mid-create harness is still adopted on 409 recovery" do
    # Content-addressing means a harness carrying this name IS this spec, so
    # adopting one mid-create is what makes 409 recovery version-correct.
    name = P.harness_name(@spec_bedrock, nil)
    create = fn _ -> {:error, {:http_error, 409, %{}}} end

    list = fn ->
      {:ok,
       %{
         "harnesses" => [
           %{
             "harnessName" => name,
             "harnessId" => "h9",
             "arn" => "arn:harness/exist",
             "status" => "CREATING"
           }
         ]
       }}
    end

    get_fun = fn _ -> {:ok, %{"harness" => %{"status" => "READY"}}} end

    assert {:ok, %{harness_arn: "arn:harness/exist", harness_id: "h9"}} =
             P.provision(@spec_bedrock,
               execution_role_arn: "role",
               create_fun: create,
               list_fun: list,
               get_fun: get_fun,
               ready_poll_ms: 0
             )
  end

  test "a harness listed without a status is never adopted" do
    name = P.harness_name(@spec_bedrock, nil)
    create = fn _ -> {:error, {:http_error, 409, %{}}} end
    list = fn -> {:ok, %{"harnesses" => [%{"harnessName" => name, "harnessId" => "h9"}]}} end

    assert {:error, {:harness_name_conflict, ^name}} =
             P.provision(@spec_bedrock,
               execution_role_arn: "role",
               create_fun: create,
               list_fun: list,
               ready_poll_ms: 0
             )
  end
end
