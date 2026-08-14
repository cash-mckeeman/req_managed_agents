defmodule ReqManagedAgents.Providers.BedrockAgentCoreTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias ReqManagedAgents.Agent.Spec
  alias ReqManagedAgents.AgentCore.Client
  alias ReqManagedAgents.Environment.Spec, as: EnvSpec
  alias ReqManagedAgents.Providers.BedrockAgentCore, as: P
  alias ReqManagedAgents.Providers.BedrockAgentCore.HarnessSpec
  alias ReqManagedAgents.Providers.BedrockAgentCore.WaitContext
  alias ReqManagedAgents.{ToolUse, TurnResult}

  defp start_block(idx, id, name),
    do: %{
      "contentBlockStart" => %{
        "contentBlockIndex" => idx,
        "start" => %{"toolUse" => %{"toolUseId" => id, "name" => name}}
      }
    }

  defp delta(idx, frag),
    do: %{
      "contentBlockDelta" => %{
        "contentBlockIndex" => idx,
        "delta" => %{"toolUse" => %{"input" => frag}}
      }
    }

  defp tool_stop, do: %{"messageStop" => %{"stopReason" => "tool_use"}}

  defp conn(invoke_fun),
    do:
      elem(
        P.open(
          [
            harness_arn: "arn",
            runtime_session_id: String.duplicate("s", 33),
            invoke_fun: invoke_fun
          ],
          self()
        ),
        1
      )

  # ── normalize ─────────────────────────────────────────────────────────────────
  test "normalize/1 surfaces usage from the Converse metadata frame" do
    events = [
      %{"messageStop" => %{"stopReason" => "end_turn"}},
      %{
        "metadata" => %{
          "usage" => %{"inputTokens" => 12, "outputTokens" => 7, "totalTokens" => 19}
        }
      }
    ]

    assert %ReqManagedAgents.TurnResult{
             usage: %ReqManagedAgents.Usage{
               input_tokens: 12,
               output_tokens: 7,
               raw: [%{"inputTokens" => 12}]
             }
           } =
             P.normalize(events)
  end

  test "normalize/1 maps a tool_use turn to a %TurnResult{} with %ToolUse{}" do
    events = [
      %{
        "contentBlockStart" => %{
          "contentBlockIndex" => 0,
          "start" => %{"toolUse" => %{"toolUseId" => "t1", "name" => "lookup"}}
        }
      },
      %{
        "contentBlockDelta" => %{
          "contentBlockIndex" => 0,
          "delta" => %{"toolUse" => %{"input" => "{\"text\":\"hi\"}"}}
        }
      },
      %{"messageStop" => %{"stopReason" => "tool_use"}}
    ]

    assert %TurnResult{
             terminal: :requires_action,
             stop_reason: "tool_use",
             custom_tool_uses: [%ToolUse{id: "t1", name: "lookup", input: %{"text" => "hi"}}],
             server_tool_uses: []
           } = P.normalize(events)
  end

  test "normalize/1 maps an end_turn to a %TurnResult{}" do
    assert %TurnResult{
             terminal: :end_turn,
             stop_reason: "end_turn",
             custom_tool_uses: [],
             text: "done."
           } =
             P.normalize([
               %{"messageStop" => %{"stopReason" => "end_turn"}},
               %{
                 "contentBlockDelta" => %{
                   "contentBlockIndex" => 0,
                   "delta" => %{"text" => "done."}
                 }
               }
             ])
  end

  test "terminal collapses to the canonical three atoms" do
    assert P.terminal("end_turn") == :end_turn
    assert P.terminal("stop_sequence") == :end_turn
    assert P.terminal("tool_use") == :requires_action
    assert P.terminal("max_tokens") == :terminated
    assert P.terminal("anything") == :terminated
  end

  test "regression: a reused contentBlockIndex recovers BOTH distinct tools" do
    events = [start_block(0, "tu_A", "f"), start_block(0, "tu_B", "g"), tool_stop()]
    assert ["tu_A", "tu_B"] = Enum.map(P.normalize(events).custom_tool_uses, & &1.id)
  end

  test "server-side exclusion: unrecognized content never enters custom_tool_uses; server_tool_uses is []" do
    events = [
      %{
        "contentBlockStart" => %{
          "contentBlockIndex" => 0,
          "start" => %{"someServerTool" => %{"name" => "x"}}
        }
      },
      start_block(1, "tu_1", "echo"),
      delta(1, ~s({})),
      tool_stop()
    ]

    out = P.normalize(events)
    assert [%{id: "tu_1"}] = out.custom_tool_uses
    assert out.server_tool_uses == []
  end

  # ── invocation ────────────────────────────────────────────────────────────────
  test "mode/0 is :request_response" do
    assert P.mode() == :request_response
  end

  describe "text_delta/1" do
    test "maps contentBlockDelta text to a chunk" do
      ev = %{"contentBlockDelta" => %{"contentBlockIndex" => 0, "delta" => %{"text" => "chunk"}}}
      assert P.text_delta(ev) == "chunk"
    end

    test "toolUse deltas and other envelopes yield nil" do
      assert P.text_delta(%{
               "contentBlockDelta" => %{"delta" => %{"toolUse" => %{"input" => "{}"}}}
             }) == nil

      assert P.text_delta(%{"messageStop" => %{}}) == nil
    end
  end

  test "kickoff_input/1 and user_input/1 build user messages" do
    assert P.kickoff_input(prompt: "go") == [
             %{"role" => "user", "content" => [%{"text" => "go"}]}
           ]

    assert P.user_input("hi") == [%{"role" => "user", "content" => [%{"text" => "hi"}]}]
  end

  test "resume_input/2 produces the strict two-message delta" do
    uses = [%ToolUse{id: "tu_1", name: "echo", input: %{"text" => "hi"}}]
    results = [%{tool_use_id: "tu_1", text: "echoed: hi", is_error: false}]

    assert [%{"role" => "assistant", "content" => [%{"toolUse" => tu}]}, user] =
             P.resume_input(uses, results)

    assert tu == %{"toolUseId" => "tu_1", "name" => "echo", "input" => %{"text" => "hi"}}
    assert get_in(user, ["content", Access.at(0), "toolResult", "status"]) == "success"
  end

  test "poll_turn/2 returns a turn's events" do
    events = [%{"messageStop" => %{"stopReason" => "end_turn"}}]
    assert {:ok, ^events, _conn} = P.poll_turn(conn(fn _inv -> {:ok, events} end), [])
  end

  test "poll_turn/2 surfaces a __stream_error__ frame as a harness_stream_error" do
    events = [%{"__stream_error__" => %{"type" => "ValidationException", "message" => "boom"}}]

    assert {:error, {:harness_stream_error, "ValidationException", "boom"}} =
             P.poll_turn(conn(fn _inv -> {:ok, events} end), [])
  end

  test "poll_turn/2 retries a truncated turn (no terminal stop_reason) then surfaces it" do
    # First call: truncated (no messageStop). Retry: a clean end_turn.
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    invoke_fun = fn _inv ->
      n = Agent.get_and_update(agent, &{&1, &1 + 1})
      if n == 0, do: {:ok, []}, else: {:ok, [%{"messageStop" => %{"stopReason" => "end_turn"}}]}
    end

    assert {:ok, [%{"messageStop" => _}], _conn} = P.poll_turn(conn(invoke_fun), [])
  end

  test "implements the Provider behaviour callbacks" do
    Code.ensure_loaded!(P)

    for {f, a} <- [
          {:mode, 0},
          {:open, 2},
          {:kickoff_input, 1},
          {:user_input, 1},
          {:resume_input, 2},
          {:normalize, 1},
          {:poll_turn, 2}
        ] do
      assert function_exported?(P, f, a)
    end
  end

  # ── provision / teardown ──────────────────────────────────────────────────────

  # `provision/2` now requires a Spec-shaped map WITH `:name` (Agent.Spec.new/1 coerces
  # the boundary — see #70); `:name` is excluded from Agent.Spec.digest/1's hashed
  # content, so its presence here doesn't affect any digest byte-identity assertion.
  @spec_bedrock %{
    name: "harness",
    system_prompt: "be helpful",
    tools: [%{"name" => "t"}],
    terminal_tool: nil,
    model_config: %{"bedrockModelConfig" => %{"modelId" => "anthropic.claude-sonnet-4"}}
  }

  # delete_fun is defaulted deliberately: rollback/2 otherwise falls back to a real
  # Client.delete_harness/2 against a live signed endpoint with a 600 s timeout, and
  # swallows the outcome — so a future test whose ready-wait fails under this helper
  # would silently reach AWS instead of failing offline.
  defp prov_opts(create_fun, extra \\ []) do
    [
      execution_role_arn: "arn:aws:iam::1:role/R",
      create_fun: create_fun,
      get_fun: fn _hid -> {:ok, %{"harness" => %{"status" => "READY"}}} end,
      endpoint_fun: ready_endpoint(),
      delete_fun: fn _hid -> {:ok, %{}} end
    ] ++ extra
  end

  # A READY harness is polled a second time, for its endpoint, so every provision
  # that reaches READY needs this seam injected too — otherwise it reaches a real
  # signed AWS endpoint the way an un-injected get_fun would.
  defp ready_endpoint, do: fn _hid, _name -> {:ok, %{"endpoint" => %{"status" => "READY"}}} end

  defp endpoint_status(status),
    do: fn _hid, _name -> {:ok, %{"endpoint" => %{"status" => status}}} end

  defp harness_ready, do: fn _hid -> {:ok, %{"harness" => %{"status" => "READY"}}} end

  defp created(hid),
    do: fn _spec -> {:ok, %{"harness" => %{"arn" => "a", "harnessId" => hid}}} end

  # The create counterpart of `reporting_delete/0`: an opt rejected at entry must
  # cost no CreateHarness at all, and only a reporting stub can tell "rejected
  # before the create" from "created, then rejected".
  defp reporting_create(hid) do
    test_pid = self()

    fn _spec ->
      send(test_pid, {:created, hid})
      {:ok, %{"harness" => %{"arn" => "a", "harnessId" => hid}}}
    end
  end

  # Reports rather than absorbing: a stub that quietly answers {:ok, %{}} would
  # let a test assert a failure while the rollback it depends on never ran.
  defp reporting_delete do
    test_pid = self()

    fn hid ->
      send(test_pid, {:deleted, hid})
      {:ok, %{}}
    end
  end

  describe "build_spec/2" do
    test "blank execution_role_arn is rejected with a clear message, not passed to AWS" do
      assert {:error, {:invalid_opts, :execution_role_arn}} =
               P.build_spec(@spec_bedrock, execution_role_arn: "  ")
    end

    test "nil execution_role_arn is rejected" do
      assert {:error, {:invalid_opts, :execution_role_arn}} =
               P.build_spec(@spec_bedrock, [])
    end

    test "a well-formed arn passes validation and is preserved in the spec" do
      assert {:ok, %{execution_role_arn: "arn:aws:iam::123:role/R"}} =
               P.build_spec(@spec_bedrock, execution_role_arn: "arn:aws:iam::123:role/R")
    end

    test "build_spec/2 returns a %HarnessSpec{} with validated fields" do
      spec = %Spec{name: "h", system_prompt: "hi", model_config: "claude-sonnet-4-6"}

      assert {:ok,
              %HarnessSpec{
                execution_role_arn: "arn:aws:iam::000000000000:role/R",
                model: "claude-sonnet-4-6"
              }} =
               P.build_spec(spec, execution_role_arn: "arn:aws:iam::000000000000:role/R")
    end

    test "blank execution_role_arn is still rejected" do
      spec = %Spec{name: "h", system_prompt: "hi"}

      assert {:error, {:invalid_opts, :execution_role_arn}} =
               P.build_spec(spec, execution_role_arn: "  ")
    end
  end

  test "provision/2 creates a harness, polls READY, returns {harness_arn, harness_id}" do
    create = fn harness_spec ->
      assert harness_spec.system_prompt == "be helpful"
      assert harness_spec.model == @spec_bedrock.model_config
      assert harness_spec.execution_role_arn == "arn:aws:iam::1:role/R"
      assert is_binary(harness_spec.name)
      {:ok, %{"harness" => %{"arn" => "arn:harness/x", "harnessId" => "h1"}}}
    end

    assert {:ok, %{harness_arn: "arn:harness/x", harness_id: "h1"}} =
             P.provision(@spec_bedrock, prov_opts(create))
  end

  test "provision/2 coerces a bare Agent.Spec-shaped map at the boundary (#70)" do
    create = fn harness_spec ->
      assert harness_spec.system_prompt == "coerce me"
      {:ok, %{"harness" => %{"arn" => "arn:harness/x", "harnessId" => "h1"}}}
    end

    spec = %{
      name: "coerced-harness",
      system_prompt: "coerce me",
      tools: [],
      terminal_tool: nil,
      model_config: %{"bedrockModelConfig" => %{"modelId" => "m"}}
    }

    assert {:ok, %{harness_arn: "arn:harness/x", harness_id: "h1"}} =
             P.provision(spec, prov_opts(create))
  end

  test "provision/2 rejects an invalid spec (missing :name) with {:error, :invalid_agent_spec} (#70)" do
    assert {:error, :invalid_agent_spec} =
             P.provision(%{system_prompt: "no name here"},
               execution_role_arn: "arn:aws:iam::1:role/R"
             )
  end

  test "provision/2 recovers an existing harness when CreateHarness 409s" do
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
             "status" => "READY"
           }
         ]
       }}
    end

    assert {:ok, %{harness_arn: "arn:harness/exist", harness_id: "h9"}} =
             P.provision(@spec_bedrock, prov_opts(create, list_fun: list))
  end

  test "provision/2 returns an error (not a raise) when list_harnesses is malformed on 409" do
    create = fn _ -> {:error, {:http_error, 409, %{}}} end
    list = fn -> {:ok, %{}} end

    assert {:error, {:unexpected_list_response, {:ok, %{}}}} =
             P.provision(@spec_bedrock, prov_opts(create, list_fun: list))
  end

  test "409 caused by a DELETING same-name harness waits it out and retries the create" do
    {:ok, seq} = Agent.start_link(fn -> 0 end)
    name = P.harness_name(@spec_bedrock, nil)

    # list: call 1 (in recover) shows DELETING; call 2 (wait poll) still DELETING; call 3 gone.
    list_fun = fn ->
      n = Agent.get_and_update(seq, &{&1 + 1, &1 + 1})
      harnesses = if n >= 3, do: [], else: [%{"harnessName" => name, "status" => "DELETING"}]
      {:ok, %{"harnesses" => harnesses}}
    end

    # create: first call 409s (name still taken by the deleting one); retry succeeds.
    {:ok, creates} = Agent.start_link(fn -> 0 end)

    create_fun = fn _spec ->
      case Agent.get_and_update(creates, &{&1 + 1, &1 + 1}) do
        1 -> {:error, {:http_error, 409, "exists"}}
        _ -> {:ok, %{"harness" => %{"arn" => "arn:new", "harnessId" => "h_new"}}}
      end
    end

    get_fun = fn _hid -> {:ok, %{"harness" => %{"status" => "READY"}}} end

    assert {:ok, %{harness_arn: "arn:new", harness_id: "h_new"}} =
             P.provision(@spec_bedrock,
               execution_role_arn: "role",
               create_fun: create_fun,
               list_fun: list_fun,
               get_fun: get_fun,
               endpoint_fun: ready_endpoint(),
               ready_poll_ms: 1,
               ready_max_polls: 5
             )
  end

  test "provision/2 gives up waiting on a DELETING same-name harness that never disappears" do
    name = P.harness_name(@spec_bedrock, nil)

    # list: the same-name harness stays DELETING on every call — it never disappears.
    list_fun = fn ->
      {:ok, %{"harnesses" => [%{"harnessName" => name, "status" => "DELETING"}]}}
    end

    # create: first call 409s (name still taken); a second call would mean the retry
    # happened even though wait_until_deleted should have exhausted first.
    {:ok, creates} = Agent.start_link(fn -> 0 end)

    create_fun = fn _spec ->
      Agent.get_and_update(creates, &{&1 + 1, &1 + 1})
      {:error, {:http_error, 409, "exists"}}
    end

    get_fun = fn _hid -> {:ok, %{"harness" => %{"status" => "READY"}}} end

    assert {:error, {:harness_still_deleting, %WaitContext{harness_id: ^name, phase: :deleted}}} =
             P.provision(@spec_bedrock,
               execution_role_arn: "role",
               create_fun: create_fun,
               list_fun: list_fun,
               get_fun: get_fun,
               ready_poll_ms: 1,
               ready_max_polls: 2
             )

    assert Agent.get(creates, & &1) == 1
  end

  test "the delete-wait reports the status it actually observed, not an assumed one" do
    # The realistic shape: the harness is DELETING when recovery first lists it,
    # then the delete itself fails and it sits in DELETE_FAILED forever. Reporting
    # "DELETING" here would send the next investigation after a slow delete that
    # is not happening.
    name = P.harness_name(@spec_bedrock, nil)
    {:ok, lists} = Agent.start_link(fn -> 0 end)

    list_fun = fn ->
      n = Agent.get_and_update(lists, &{&1 + 1, &1 + 1})
      status = if n == 1, do: "DELETING", else: "DELETE_FAILED"
      {:ok, %{"harnesses" => [%{"harnessName" => name, "status" => status}]}}
    end

    assert {:error, {:harness_still_deleting, %WaitContext{last_status: "DELETE_FAILED"}}} =
             P.provision(@spec_bedrock,
               execution_role_arn: "role",
               create_fun: fn _ -> {:error, {:http_error, 409, "exists"}} end,
               list_fun: list_fun,
               get_fun: fn _hid -> {:ok, %{"harness" => %{"status" => "READY"}}} end,
               ready_poll_ms: 0,
               ready_max_polls: 2
             )
  end

  test "provision/2 still returns a name conflict when the same-name harness has a *_FAILED status" do
    name = P.harness_name(@spec_bedrock, nil)
    create = fn _ -> {:error, {:http_error, 409, %{}}} end

    list = fn ->
      {:ok, %{"harnesses" => [%{"harnessName" => name, "status" => "CREATE_FAILED"}]}}
    end

    assert {:error, {:harness_name_conflict, ^name}} =
             P.provision(@spec_bedrock, prov_opts(create, list_fun: list))
  end

  test "teardown/2 deletes the harness by id" do
    {:ok, deleted} = Agent.start_link(fn -> nil end)

    delete = fn hid ->
      Agent.update(deleted, fn _ -> hid end)
      {:ok, %{}}
    end

    assert :ok = P.teardown(%{harness_arn: "a", harness_id: "h1"}, delete_fun: delete)
    assert Agent.get(deleted, & &1) == "h1"
  end

  test "provision/2 polls until READY (retry path)" do
    {:ok, n} = Agent.start_link(fn -> 0 end)

    get = fn _ ->
      i = Agent.get_and_update(n, &{&1, &1 + 1})

      if i == 0,
        do: {:ok, %{"harness" => %{"status" => "CREATING"}}},
        else: {:ok, %{"harness" => %{"status" => "READY"}}}
    end

    create = fn _ -> {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "h"}}} end

    assert {:ok, %{harness_arn: "a"}} =
             P.provision(@spec_bedrock,
               execution_role_arn: "r",
               create_fun: create,
               get_fun: get,
               endpoint_fun: ready_endpoint(),
               ready_poll_ms: 0
             )
  end

  test "provision/2 surfaces a CREATE_FAILED harness" do
    create = fn _ -> {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "h"}}} end
    get = fn _ -> {:ok, %{"harness" => %{"status" => "CREATE_FAILED"}}} end

    assert {:error, {:harness_failed, %WaitContext{last_status: "CREATE_FAILED"}}} =
             P.provision(@spec_bedrock,
               execution_role_arn: "r",
               create_fun: create,
               get_fun: get,
               delete_fun: fn _ -> {:ok, %{}} end,
               ready_poll_ms: 0
             )
  end

  describe "create-response drift" do
    @drifted {:ok, %{"harness" => %{"arn" => "a"}}}

    test "a 2xx create body missing harnessId is an error, not a handle" do
      assert {:error, {:unexpected_create_response, @drifted}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: fn _ -> @drifted end,
                 ready_poll_ms: 0
               )
    end

    test "the recreate path rejects a drifted body instead of returning it as the handle" do
      # This is the path that could poison the provision cache: its `with` had no
      # else clause, so a drifted body flowed out of provision/2 as {:ok, ...} and
      # was stored, and every later ensure/3 served it.
      name = P.harness_name(@spec_bedrock, nil)
      {:ok, lists} = Agent.start_link(fn -> 0 end)

      list_fun = fn ->
        n = Agent.get_and_update(lists, &{&1 + 1, &1 + 1})
        harnesses = if n >= 2, do: [], else: [%{"harnessName" => name, "status" => "DELETING"}]
        {:ok, %{"harnesses" => harnesses}}
      end

      {:ok, creates} = Agent.start_link(fn -> 0 end)

      create_fun = fn _ ->
        case Agent.get_and_update(creates, &{&1 + 1, &1 + 1}) do
          1 -> {:error, {:http_error, 409, "exists"}}
          _ -> @drifted
        end
      end

      assert {:error, {:unexpected_create_response, @drifted}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: create_fun,
                 list_fun: list_fun,
                 ready_poll_ms: 0
               )
    end

    test "a create body with a non-binary id is drift too" do
      drifted = {:ok, %{"harness" => %{"arn" => "a", "harnessId" => nil}}}

      assert {:error, {:unexpected_create_response, ^drifted}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: fn _ -> drifted end,
                 ready_poll_ms: 0
               )
    end
  end

  # ── rollback on a post-create failure ────────────────────────────────────────

  describe "rollback" do
    test "a ready-failure rolls the created harness back" do
      test_pid = self()

      delete_fun = fn hid ->
        send(test_pid, {:deleted, hid})
        {:ok, %{}}
      end

      get_fun = fn _ -> {:ok, %{"harness" => %{"status" => "CREATE_FAILED"}}} end

      assert {:error, {:harness_failed, %WaitContext{harness_id: "h"}}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: fn _ ->
                   {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "h"}}}
                 end,
                 get_fun: get_fun,
                 delete_fun: delete_fun,
                 ready_poll_ms: 0
               )

      assert_receive {:deleted, "h"}
    end

    test "a ready-timeout rolls the created harness back instead of orphaning it" do
      test_pid = self()

      delete_fun = fn hid ->
        send(test_pid, {:deleted, hid})
        {:ok, %{}}
      end

      assert {:error, {:harness_ready_timeout, %WaitContext{last_status: "CREATING", polls: 2}}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: fn _ ->
                   {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "h"}}}
                 end,
                 get_fun: fn _ -> {:ok, %{"harness" => %{"status" => "CREATING"}}} end,
                 delete_fun: delete_fun,
                 ready_poll_ms: 0,
                 ready_max_polls: 1
               )

      assert_receive {:deleted, "h"}
    end

    test "rollback failure never masks the original error" do
      get_fun = fn _ -> {:ok, %{"harness" => %{"status" => "CREATE_FAILED"}}} end

      assert {:error, {:harness_failed, %WaitContext{}}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: fn _ ->
                   {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "h"}}}
                 end,
                 get_fun: get_fun,
                 delete_fun: fn _ -> {:error, :boom} end,
                 ready_poll_ms: 0
               )
    end

    test "the recreate path rolls back a harness it created after waiting out a delete" do
      # deleting -> wait it out -> create -> ready-failure. This create is as much
      # this call's own as the first one, so it must roll back too.
      test_pid = self()
      name = P.harness_name(@spec_bedrock, nil)
      {:ok, lists} = Agent.start_link(fn -> 0 end)

      list_fun = fn ->
        n = Agent.get_and_update(lists, &{&1 + 1, &1 + 1})
        harnesses = if n >= 2, do: [], else: [%{"harnessName" => name, "status" => "DELETING"}]
        {:ok, %{"harnesses" => harnesses}}
      end

      {:ok, creates} = Agent.start_link(fn -> 0 end)

      create_fun = fn _ ->
        case Agent.get_and_update(creates, &{&1 + 1, &1 + 1}) do
          1 -> {:error, {:http_error, 409, "exists"}}
          _ -> {:ok, %{"harness" => %{"arn" => "arn:new", "harnessId" => "h_new"}}}
        end
      end

      assert {:error, {:harness_failed, %WaitContext{harness_id: "h_new"}}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: create_fun,
                 list_fun: list_fun,
                 get_fun: fn _ -> {:ok, %{"harness" => %{"status" => "CREATE_FAILED"}}} end,
                 delete_fun: fn hid ->
                   send(test_pid, {:deleted, hid})
                   {:ok, %{}}
                 end,
                 ready_poll_ms: 0
               )

      assert_receive {:deleted, "h_new"}
    end

    test "an exiting poll still rolls the created harness back" do
      # `rescue` catches class :error only. The production get_fun runs through
      # :telemetry.span, Req, Finch and NimblePool, any of which can surface an
      # exit — which would have skipped rollback entirely.
      test_pid = self()

      assert catch_exit(
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: fn _ ->
                   {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "h"}}}
                 end,
                 get_fun: fn _ -> exit(:boom) end,
                 delete_fun: fn hid ->
                   send(test_pid, {:deleted, hid})
                   {:ok, %{}}
                 end,
                 ready_poll_ms: 0
               )
             ) == :boom

      assert_receive {:deleted, "h"}
    end

    test "a throwing poll still rolls the created harness back" do
      test_pid = self()

      assert catch_throw(
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: fn _ ->
                   {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "h"}}}
                 end,
                 get_fun: fn _ -> throw(:nope) end,
                 delete_fun: fn hid ->
                   send(test_pid, {:deleted, hid})
                   {:ok, %{}}
                 end,
                 ready_poll_ms: 0
               )
             ) == :nope

      assert_receive {:deleted, "h"}
    end

    test "a rollback that exits never masks the original error" do
      assert {:error, {:harness_failed, %WaitContext{}}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: fn _ ->
                   {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "h"}}}
                 end,
                 get_fun: fn _ -> {:ok, %{"harness" => %{"status" => "CREATE_FAILED"}}} end,
                 delete_fun: fn _ -> exit(:delete_died) end,
                 ready_poll_ms: 0
               )
    end

    test "a rollback that raises never masks the original error" do
      get_fun = fn _ -> {:ok, %{"harness" => %{"status" => "CREATE_FAILED"}}} end

      assert {:error, {:harness_failed, %WaitContext{}}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: fn _ ->
                   {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "h"}}}
                 end,
                 get_fun: get_fun,
                 delete_fun: fn _ -> raise "delete blew up" end,
                 ready_poll_ms: 0
               )
    end

    test "an adopted harness this call did not create is never rolled back" do
      # Deleting a harness we merely recovered would destroy a resource another
      # caller owns — rollback covers only what this call created.
      test_pid = self()
      name = P.harness_name(@spec_bedrock, nil)

      list = fn ->
        {:ok,
         %{
           "harnesses" => [
             %{
               "harnessName" => name,
               "harnessId" => "h9",
               "arn" => "arn:harness/exist",
               "status" => "READY"
             }
           ]
         }}
      end

      assert {:error, {:harness_failed, %WaitContext{harness_id: "h9"}}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: fn _ -> {:error, {:http_error, 409, %{}}} end,
                 list_fun: list,
                 get_fun: fn _ -> {:ok, %{"harness" => %{"status" => "CREATE_FAILED"}}} end,
                 delete_fun: fn hid ->
                   send(test_pid, {:deleted, hid})
                   {:ok, %{}}
                 end,
                 ready_poll_ms: 0
               )

      refute_receive {:deleted, _}
    end
  end

  # ── endpoint readiness ───────────────────────────────────────────────────────
  #
  # A harness and its DEFAULT endpoint carry separate statuses and reach READY at
  # different times — measured live, 11 s against 2 m 31 s. A handle returned on
  # the harness status alone therefore names an endpoint that cannot yet be
  # invoked, which is what these pin.

  # A name the service can never resolve is indistinguishable from an endpoint
  # that has not appeared yet: GetHarnessEndpoint 404s, the 404 is treated as
  # "still creating", and the wait burns the whole budget. That wait sits inside
  # the rollback, so the provision then DELETES a harness that is healthy and
  # READY. Rejecting the name at entry is what makes the typo free.
  describe ":endpoint_name validation" do
    test "an endpoint name outside the service pattern is rejected before anything is created" do
      assert {:error, {:invalid_opts, :endpoint_name}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 endpoint_name: "Defualt endpoint!",
                 create_fun: reporting_create("h_bad_ep"),
                 get_fun: harness_ready(),
                 endpoint_fun: ready_endpoint(),
                 delete_fun: reporting_delete(),
                 ready_poll_ms: 0
               )

      refute_received {:created, _}
      refute_received {:deleted, _}
    end

    test "the pattern is the endpoint's own: 48 characters, not the harness name's 40" do
      long = "e" <> String.duplicate("a", 47)
      too_long = long <> "a"

      assert {:ok, _} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 endpoint_name: long,
                 create_fun: created("h_48"),
                 get_fun: harness_ready(),
                 endpoint_fun: ready_endpoint(),
                 delete_fun: reporting_delete(),
                 ready_poll_ms: 0
               )

      assert {:error, {:invalid_opts, :endpoint_name}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 endpoint_name: too_long,
                 create_fun: reporting_create("h_49"),
                 get_fun: harness_ready(),
                 endpoint_fun: ready_endpoint(),
                 delete_fun: reporting_delete(),
                 ready_poll_ms: 0
               )

      refute_received {:created, _}
    end

    test "a name that does not start with a letter, and a non-binary, are both rejected" do
      for bad <- ["1prod", "_prod", "", :DEFAULT] do
        assert {:error, {:invalid_opts, :endpoint_name}} =
                 P.provision(@spec_bedrock,
                   execution_role_arn: "r",
                   endpoint_name: bad,
                   create_fun: reporting_create("h_bad"),
                   get_fun: harness_ready(),
                   endpoint_fun: ready_endpoint(),
                   delete_fun: reporting_delete(),
                   ready_poll_ms: 0
                 )
      end

      refute_received {:created, _}
    end

    test "an endpoint wait names the endpoint it was waiting on, in the context and the log" do
      # `last_status=none` on a 404-only wait says nothing about WHICH endpoint was
      # missing, and with the name caller-configurable that is the first thing to
      # check.
      log =
        capture_log([level: :info], fn ->
          assert {:error, {:endpoint_ready_timeout, %WaitContext{endpoint_name: "canary"}}} =
                   P.provision(@spec_bedrock,
                     execution_role_arn: "r",
                     endpoint_name: "canary",
                     create_fun: created("h_ep_named"),
                     get_fun: harness_ready(),
                     endpoint_fun: fn _hid, _name ->
                       {:error, {:http_error, 404, %{"message" => "not found"}}}
                     end,
                     delete_fun: reporting_delete(),
                     ready_poll_ms: 0,
                     ready_max_polls: 2
                   )
        end)

      assert log =~ "endpoint=canary"
      assert_receive {:deleted, "h_ep_named"}
    end
  end

  describe "endpoint readiness" do
    test "a READY harness whose endpoint is still creating is not a ready provision" do
      assert {:error,
              {:endpoint_ready_timeout,
               %WaitContext{harness_id: "h_ep", phase: :endpoint, last_status: "CREATING"}}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: created("h_ep"),
                 get_fun: harness_ready(),
                 endpoint_fun: endpoint_status("CREATING"),
                 delete_fun: reporting_delete(),
                 ready_poll_ms: 0,
                 ready_max_polls: 2
               )

      # The harness is this call's own, and a provision that gave up on it must
      # not leave it billing.
      assert_receive {:deleted, "h_ep"}
    end

    test "the handle is returned once BOTH the harness and its endpoint are READY" do
      {:ok, polls} = Agent.start_link(fn -> 0 end)

      endpoint_fun = fn _hid, _name ->
        n = Agent.get_and_update(polls, &{&1 + 1, &1 + 1})
        status = if n == 1, do: "CREATING", else: "READY"
        {:ok, %{"endpoint" => %{"status" => status}}}
      end

      assert {:ok, %{harness_arn: "a", harness_id: "h_both"}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: created("h_both"),
                 get_fun: harness_ready(),
                 endpoint_fun: endpoint_fun,
                 delete_fun: reporting_delete(),
                 ready_poll_ms: 0
               )

      assert Agent.get(polls, & &1) == 2
      refute_received {:deleted, _}
    end

    test "the endpoint is polled only once the harness is READY, not once per harness poll" do
      # Gating it behind harness readiness is what keeps the common path at ONE
      # extra call. An ungated check would poll the endpoint on every harness
      # poll, and a harness that never becomes READY would still be asking about
      # an endpoint that cannot exist.
      test_pid = self()

      endpoint_fun = fn hid, name ->
        send(test_pid, {:endpoint_polled, hid, name})
        {:ok, %{"endpoint" => %{"status" => "READY"}}}
      end

      assert {:error, {:harness_ready_timeout, %WaitContext{phase: :ready}}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: created("h_gated"),
                 get_fun: fn _hid -> {:ok, %{"harness" => %{"status" => "CREATING"}}} end,
                 endpoint_fun: endpoint_fun,
                 delete_fun: reporting_delete(),
                 ready_poll_ms: 0,
                 ready_max_polls: 3
               )

      refute_received {:endpoint_polled, _, _}
      assert_receive {:deleted, "h_gated"}
    end

    test "endpoint_fun receives the harness id and the endpoint the data plane defaults to" do
      # `qualifier` is optional on InvokeHarness and defaults to DEFAULT, so
      # DEFAULT is the endpoint an invoke actually reaches — waiting on any other
      # one would gate readiness on an endpoint nobody calls.
      test_pid = self()

      endpoint_fun = fn hid, name ->
        send(test_pid, {:endpoint_polled, hid, name})
        {:ok, %{"endpoint" => %{"status" => "READY"}}}
      end

      assert {:ok, _} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: created("h_threaded_ep"),
                 get_fun: harness_ready(),
                 endpoint_fun: endpoint_fun,
                 delete_fun: reporting_delete(),
                 ready_poll_ms: 0
               )

      assert_receive {:endpoint_polled, "h_threaded_ep", "DEFAULT"}
    end

    test ":endpoint_name overrides which endpoint readiness is gated on" do
      test_pid = self()

      endpoint_fun = fn _hid, name ->
        send(test_pid, {:endpoint_polled, name})
        {:ok, %{"endpoint" => %{"status" => "READY"}}}
      end

      assert {:ok, _} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: created("h_named_ep"),
                 get_fun: harness_ready(),
                 endpoint_fun: endpoint_fun,
                 endpoint_name: "canary",
                 delete_fun: reporting_delete(),
                 ready_poll_ms: 0
               )

      assert_receive {:endpoint_polled, "canary"}
    end

    test "an endpoint that has not appeared yet is waited on, not failed" do
      # CreateHarness provisions the DEFAULT endpoint asynchronously, so a 404
      # early in the wait means "not there yet". Failing on it would turn a normal
      # create into a provisioning error.
      {:ok, polls} = Agent.start_link(fn -> 0 end)

      endpoint_fun = fn _hid, _name ->
        case Agent.get_and_update(polls, &{&1 + 1, &1 + 1}) do
          0 -> {:error, {:http_error, 404, %{"message" => "not found"}}}
          _ -> {:ok, %{"endpoint" => %{"status" => "READY"}}}
        end
      end

      assert {:ok, %{harness_id: "h_404"}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: created("h_404"),
                 get_fun: harness_ready(),
                 endpoint_fun: endpoint_fun,
                 delete_fun: reporting_delete(),
                 ready_poll_ms: 0
               )

      refute_received {:deleted, _}
    end

    test "a failed endpoint fails the provision and rolls the harness back" do
      assert {:error,
              {:endpoint_failed, %WaitContext{phase: :endpoint, last_status: "CREATE_FAILED"}}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: created("h_ep_failed"),
                 get_fun: harness_ready(),
                 endpoint_fun: endpoint_status("CREATE_FAILED"),
                 delete_fun: reporting_delete(),
                 ready_poll_ms: 0
               )

      assert_receive {:deleted, "h_ep_failed"}
    end

    test "a DELETING endpoint terminates the wait rather than polling it out" do
      assert {:error,
              {:endpoint_terminating, %WaitContext{phase: :endpoint, last_status: "DELETING"}}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: created("h_ep_deleting"),
                 get_fun: harness_ready(),
                 endpoint_fun: endpoint_status("DELETING"),
                 delete_fun: reporting_delete(),
                 ready_poll_ms: 0
               )

      assert_receive {:deleted, "h_ep_deleting"}
    end

    test "an unrecognised endpoint status is named, not polled until the budget is gone" do
      assert {:error,
              {:endpoint_unknown_status, %WaitContext{phase: :endpoint, last_status: "INACTIVE"}}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: created("h_ep_unknown"),
                 get_fun: harness_ready(),
                 endpoint_fun: endpoint_status("INACTIVE"),
                 delete_fun: reporting_delete(),
                 ready_poll_ms: 0
               )

      assert_receive {:deleted, "h_ep_unknown"}
    end

    test "an adopted harness whose endpoint never becomes ready is NOT rolled back" do
      # The endpoint wait applies on the recovery path too — a 409-recovered
      # harness is just as unusable with a creating endpoint — but the harness
      # belongs to whoever created it, so this call must not delete it.
      name = P.harness_name(@spec_bedrock, nil)

      list = fn ->
        {:ok,
         %{
           "harnesses" => [
             %{
               "harnessName" => name,
               "harnessId" => "h_adopted",
               "arn" => "arn:harness/exist",
               "status" => "READY"
             }
           ]
         }}
      end

      assert {:error, {:endpoint_ready_timeout, %WaitContext{harness_id: "h_adopted"}}} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: fn _ -> {:error, {:http_error, 409, %{}}} end,
                 list_fun: list,
                 get_fun: harness_ready(),
                 endpoint_fun: endpoint_status("CREATING"),
                 delete_fun: reporting_delete(),
                 ready_poll_ms: 0,
                 ready_max_polls: 2
               )

      refute_receive {:deleted, _}
    end

    test "an endpoint failure is diagnosable from the log alone" do
      log =
        capture_log([level: :info], fn ->
          assert {:error, {:endpoint_failed, _}} =
                   P.provision(@spec_bedrock,
                     execution_role_arn: "r",
                     create_fun: created("h_ep_log"),
                     get_fun: harness_ready(),
                     endpoint_fun: endpoint_status("UPDATE_FAILED"),
                     delete_fun: reporting_delete(),
                     ready_poll_ms: 0
                   )
        end)

      assert log =~ "harness_id=h_ep_log"
      assert log =~ "phase=endpoint"
      assert log =~ "last_status=UPDATE_FAILED"
      assert log =~ "endpoint_failed"
    end
  end

  test "get_fun receives the harness id it was given" do
    # Every other stub ignores its argument, so an id-threading regression — polling
    # the wrong harness — would be invisible to the whole suite.
    test_pid = self()

    assert {:ok, %{harness_id: "h_threaded"}} =
             P.provision(@spec_bedrock,
               execution_role_arn: "r",
               create_fun: fn _ ->
                 {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "h_threaded"}}}
               end,
               get_fun: fn hid ->
                 send(test_pid, {:polled, hid})
                 {:ok, %{"harness" => %{"status" => "READY"}}}
               end,
               endpoint_fun: ready_endpoint(),
               ready_poll_ms: 0
             )

    assert_receive {:polled, "h_threaded"}
  end

  # ── the run-log bar ──────────────────────────────────────────────────────────
  #
  # The spec's bar is that a failure is diagnosable from the run log ALONE, with
  # no telemetry handler attached — so these assert on log output, not events.
  # Every other instrumentation test attaches a handler, which would leave the
  # actual requirement unpinned and let a refactor delete the Logger calls green.

  describe "diagnosability from the log alone" do
    test "a poll line names the harness, its status, the poll number and elapsed time" do
      log =
        capture_log([level: :debug], fn ->
          assert {:ok, _} =
                   P.provision(@spec_bedrock,
                     execution_role_arn: "r",
                     create_fun: fn _ ->
                       {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "log_poll"}}}
                     end,
                     get_fun: fn _ -> {:ok, %{"harness" => %{"status" => "READY"}}} end,
                     endpoint_fun: ready_endpoint(),
                     ready_poll_ms: 0
                   )
        end)

      assert log =~ "harness_id=log_poll"
      assert log =~ "status=READY"
      assert log =~ "poll_n=1"
      assert log =~ "elapsed_ms="
      assert log =~ "phase=ready"
    end

    test "a hard failure is visible at :info without any telemetry handler" do
      log =
        capture_log([level: :info], fn ->
          assert catch_exit(
                   P.provision(@spec_bedrock,
                     execution_role_arn: "r",
                     create_fun: fn _ ->
                       {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "log_exit"}}}
                     end,
                     get_fun: fn _ -> exit(:boom) end,
                     delete_fun: fn _ -> {:ok, %{}} end,
                     ready_poll_ms: 0
                   )
                 ) == :boom
        end)

      assert log =~ "harness_id=log_exit"
      assert log =~ "kind=exit"
      assert log =~ "failed hard"
    end

    test "a delete-wait that gave up unconfirmed says so, rather than logging only :ok" do
      name = P.harness_name(@spec_bedrock, nil)
      {:ok, lists} = Agent.start_link(fn -> 0 end)

      list_fun = fn ->
        case Agent.get_and_update(lists, &{&1 + 1, &1 + 1}) do
          1 -> {:ok, %{"harnesses" => [%{"harnessName" => name, "status" => "DELETING"}]}}
          _ -> {:error, :listing_down}
        end
      end

      log =
        capture_log([level: :info], fn ->
          P.provision(@spec_bedrock,
            execution_role_arn: "r",
            create_fun: fn _ -> {:error, {:http_error, 409, "exists"}} end,
            list_fun: list_fun,
            ready_poll_ms: 0
          )
        end)

      # The control flow is right — the next create arbitrates — but the stop line
      # reports result=:ok, so without this the log would claim a clean delete.
      assert log =~ "could not list harnesses"
      assert log =~ "proceeding unconfirmed"
    end

    test "a name conflict is logged rather than returned silently" do
      name = P.harness_name(@spec_bedrock, nil)

      list = fn ->
        {:ok, %{"harnesses" => [%{"harnessName" => name, "status" => "CREATE_FAILED"}]}}
      end

      log =
        capture_log([level: :info], fn ->
          assert {:error, {:harness_name_conflict, ^name}} =
                   P.provision(@spec_bedrock,
                     execution_role_arn: "r",
                     create_fun: fn _ -> {:error, {:http_error, 409, %{}}} end,
                     list_fun: list,
                     ready_poll_ms: 0
                   )
        end)

      assert log =~ "cannot recover harness #{name}"
    end

    test "the rollback outcome is logged, so an orphan is never silent" do
      log =
        capture_log([level: :info], fn ->
          assert {:error, _} =
                   P.provision(@spec_bedrock,
                     execution_role_arn: "r",
                     create_fun: fn _ ->
                       {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "log_rb"}}}
                     end,
                     get_fun: fn _ -> {:ok, %{"harness" => %{"status" => "CREATE_FAILED"}}} end,
                     delete_fun: fn _ -> {:error, :nope} end,
                     ready_poll_ms: 0
                   )
        end)

      assert log =~ "could not roll back harness log_rb"
      assert log =~ "it may be orphaned"
    end
  end

  # ── instrumentation ──────────────────────────────────────────────────────────

  describe "provision instrumentation" do
    # Telemetry handlers are global while these tests are async, so a handler here
    # also receives events from any other async test provisioning concurrently.
    # A unique harness id per test makes each assert_receive match only its own
    # events; filtering on it in the handler keeps the mailbox clean too.
    setup do
      test_pid = self()
      hid = "h_#{System.unique_integer([:positive])}"
      handler = "prov-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [
          [:req_managed_agents, :agent_core, :provision, :poll],
          [:req_managed_agents, :agent_core, :provision, :stop]
        ],
        fn
          event, meas, %{harness_id: ^hid} = meta, _ ->
            send(test_pid, {:telemetry, event, meas, meta})

          _event, _meas, _meta, _ ->
            :ok
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      {:ok, hid: hid}
    end

    test "every poll emits telemetry naming the harness and its observed status", %{hid: hid} do
      {:ok, n} = Agent.start_link(fn -> 0 end)

      get = fn _ ->
        i = Agent.get_and_update(n, &{&1, &1 + 1})

        if i == 0,
          do: {:ok, %{"harness" => %{"status" => "CREATING"}}},
          else: {:ok, %{"harness" => %{"status" => "READY"}}}
      end

      assert {:ok, _} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: fn _ ->
                   {:ok, %{"harness" => %{"arn" => "a", "harnessId" => hid}}}
                 end,
                 get_fun: get,
                 endpoint_fun: ready_endpoint(),
                 ready_poll_ms: 0
               )

      assert_receive {:telemetry, [:req_managed_agents, :agent_core, :provision, :poll],
                      %{poll_n: 1, elapsed_ms: _},
                      %{harness_id: ^hid, status: "CREATING", phase: :ready}}

      assert_receive {:telemetry, [:req_managed_agents, :agent_core, :provision, :poll],
                      %{poll_n: 2}, %{harness_id: ^hid, status: "READY", phase: :ready}}
    end

    test "a terminal outcome emits a stop event carrying the poll count and result", %{hid: hid} do
      assert {:ok, _} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: fn _ ->
                   {:ok, %{"harness" => %{"arn" => "a", "harnessId" => hid}}}
                 end,
                 get_fun: fn _ -> {:ok, %{"harness" => %{"status" => "READY"}}} end,
                 endpoint_fun: ready_endpoint(),
                 ready_poll_ms: 0
               )

      assert_receive {:telemetry, [:req_managed_agents, :agent_core, :provision, :stop],
                      %{duration_ms: _, polls: 1},
                      %{harness_id: ^hid, phase: :ready, result: :ok}}
    end

    test "a raising poll emits an exception event and does not swallow the raise", %{hid: hid} do
      handler = "prov-ex-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:req_managed_agents, :agent_core, :provision, :exception],
        fn _e, meas, meta, _ -> send(test_pid, {:exception, meas, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert_raise RuntimeError, "poll blew up", fn ->
        P.provision(@spec_bedrock,
          execution_role_arn: "r",
          create_fun: fn _ -> {:ok, %{"harness" => %{"arn" => "a", "harnessId" => hid}}} end,
          get_fun: fn _ -> raise "poll blew up" end,
          delete_fun: fn id ->
            send(test_pid, {:deleted, id})
            {:ok, %{}}
          end,
          ready_poll_ms: 0
        )
      end

      assert_receive {:exception, %{duration_ms: _},
                      %{harness_id: ^hid, phase: :ready, result: {:exception, RuntimeError}}}

      # Asserting the raise alone would pin the orphan this PR exists to close.
      assert_receive {:deleted, ^hid}
    end

    test "the stop line carries the observed status, which lives nowhere else above :debug",
         %{hid: hid} do
      log =
        capture_log([level: :info], fn ->
          assert {:error, _} =
                   P.provision(@spec_bedrock,
                     execution_role_arn: "r",
                     create_fun: fn _ ->
                       {:ok, %{"harness" => %{"arn" => "a", "harnessId" => hid}}}
                     end,
                     get_fun: fn _ -> {:ok, %{"harness" => %{"status" => "DELETING"}}} end,
                     delete_fun: fn _ -> {:ok, %{}} end,
                     ready_poll_ms: 0
                   )
        end)

      # At :info the per-poll debug lines are gone, so if the stop line omitted
      # last_status the 08-06 failure mode would be undiagnosable all over again.
      assert log =~ "last_status=DELETING"
      assert log =~ "harness_id=#{hid}"
      assert log =~ "harness_terminating"
    end

    test "a failed wait emits a stop event tagged with the failure", %{hid: hid} do
      assert {:error, _} =
               P.provision(@spec_bedrock,
                 execution_role_arn: "r",
                 create_fun: fn _ ->
                   {:ok, %{"harness" => %{"arn" => "a", "harnessId" => hid}}}
                 end,
                 get_fun: fn _ -> {:ok, %{"harness" => %{"status" => "DELETING"}}} end,
                 delete_fun: fn _ -> {:ok, %{}} end,
                 ready_poll_ms: 0
               )

      assert_receive {:telemetry, [:req_managed_agents, :agent_core, :provision, :stop],
                      %{polls: 1},
                      %{harness_id: ^hid, phase: :ready, result: {:error, :harness_terminating}}}
    end
  end

  test "provision/2's handle is accepted by open/2 (harness_arn seam)" do
    create = fn _ -> {:ok, %{"harness" => %{"arn" => "arn:h/x", "harnessId" => "h1"}}} end
    {:ok, handle} = P.provision(@spec_bedrock, prov_opts(create))

    assert {:ok, _conn} =
             P.open(
               Map.to_list(handle) ++
                 [
                   runtime_session_id: String.duplicate("s", 33),
                   invoke_fun: fn _ -> {:ok, []} end
                 ],
               self()
             )
  end

  # ── long-run threading (per-invocation budgets) ───────────────────────────────

  describe "long-run threading (per-invocation budgets)" do
    test "open/2 captures the subscriber and threads budgets; invoke carries on_event + knobs" do
      test_pid = self()

      invoke_fun = fn inv ->
        send(test_pid, {:inv, inv})
        # Exercise the on_event the provider built: it must message the subscriber.
        inv.on_event.(%{"messageStart" => %{"role" => "assistant"}})
        {:ok, [%{"messageStop" => %{"stopReason" => "end_turn"}}]}
      end

      {:ok, conn} =
        P.open(
          [
            harness_arn: "arn:aws:bedrock-agentcore:us-east-1:1:harness/ba",
            runtime_session_id: String.duplicate("s", 33),
            invoke_fun: invoke_fun,
            idle_timeout: 120_000,
            timeout_seconds: 900,
            max_iterations: 40,
            max_tokens: 4096
          ],
          self()
        )

      assert {:ok, _events, _conn} =
               P.poll_turn(conn, [
                 %{"role" => "user", "content" => [%{"text" => "hi"}]}
               ])

      assert_received {:inv, inv}
      assert inv.idle_timeout == 120_000
      assert inv.timeout_seconds == 900
      assert inv.max_iterations == 40
      assert inv.max_tokens == 4096
      assert is_function(inv.on_event, 1)
      # The on_event we invoked above delivered a live event to the subscriber (us).
      assert_received {:provider_event, %{"messageStart" => %{"role" => "assistant"}}}
    end

    test "budgets default to nil when not provided" do
      test_pid = self()

      invoke_fun = fn inv ->
        send(test_pid, {:inv, inv})
        {:ok, [%{"messageStop" => %{"stopReason" => "end_turn"}}]}
      end

      {:ok, conn} =
        P.open(
          [
            harness_arn: "arn:aws:bedrock-agentcore:us-east-1:1:harness/ba",
            runtime_session_id: String.duplicate("s", 33),
            invoke_fun: invoke_fun
          ],
          self()
        )

      assert {:ok, _events, _conn} =
               P.poll_turn(conn, [
                 %{"role" => "user", "content" => [%{"text" => "hi"}]}
               ])

      assert_received {:inv, inv}
      assert inv.idle_timeout == nil
      assert inv.timeout_seconds == nil
      assert inv.max_iterations == nil
      assert inv.max_tokens == nil
    end
  end

  test "harness_name/2's digest is byte-identical to ReqManagedAgents.Agent.Spec.digest/1 for a spec with no environment fields" do
    # harness_name/2's digest was unified onto Agent.Spec.digest/1 (previously an inline
    # :crypto.hash over the whole spec map). For a spec that only carries the identity
    # fields Agent.Spec knows about (system_prompt/tools/terminal_tool/model_config), the
    # two computations MUST agree byte-for-byte. The surrounding name shape is free to
    # change (the base now carries the spec name); the digest is not, because it is the
    # content address shared with every other provider.
    spec = %{
      system_prompt: "x",
      tools: [%{"name" => "t"}],
      terminal_tool: nil,
      model_config: %{"m" => 1}
    }

    old_digest =
      spec
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    {:ok, agent_spec} = Spec.new(Map.put(spec, :name, "harness"))
    new_digest = Spec.digest(agent_spec)

    assert old_digest == new_digest
    # Exact, not a suffix check: with no prefix and no spec name the base is empty,
    # so the leading-letter rule supplies the whole base. Pinning the exact string
    # keeps that fallback from drifting unnoticed.
    assert P.harness_name(spec, nil) == "a_#{new_digest}"
  end

  test "two specs differing only in name produce different harness names" do
    a = %{
      name: "rma-live-bedrock-harness",
      system_prompt: "p",
      tools: [],
      terminal_tool: nil,
      model_config: %{"m" => 1}
    }

    b = %{a | name: "rma-live-bedrock-reattach"}

    refute P.harness_name(a, "rma_live") == P.harness_name(b, "rma_live")
  end

  test "harness names satisfy the AWS charset and length constraint" do
    spec = %{
      name: "rma-live-bedrock-harness",
      system_prompt: "p",
      tools: [],
      terminal_tool: nil,
      model_config: %{"m" => 1}
    }

    assert P.harness_name(spec, "rma_live") =~ ~r/^[a-zA-Z][a-zA-Z0-9_]{0,39}$/
  end

  test "the live legs compose distinct, untruncated names with no prefix of their own" do
    # Each live spec name already begins with `rma-live-`, so a `name_prefix:
    # "rma_live"` on top ran the composed name past 40 characters and into the
    # truncation-hash fallback — which replaces the readable leg name with a
    # hash, on exactly the names a human reads to find a stray harness. Without
    # it every leg keeps its own segment AND the shared `rma_live` prefix a
    # sweep matches on.
    model = %{"bedrockModelConfig" => %{"modelId" => "m"}}

    names =
      for leg <- ~w(harness command mount reattach) do
        spec = %{
          name: "rma-live-bedrock-#{leg}",
          system_prompt: "p",
          tools: [],
          terminal_tool: nil,
          model_config: model
        }

        name = P.harness_name(spec, nil)
        assert name =~ ~r/^[a-zA-Z][a-zA-Z0-9_]{0,39}$/
        assert String.starts_with?(name, "rma_live_bedrock_#{leg}_")
        name
      end

    assert length(Enum.uniq(names)) == 4
  end

  test "a nil prefix still produces a valid name" do
    spec = %{
      name: "orchestrated-agent",
      system_prompt: "p",
      tools: [],
      terminal_tool: nil,
      model_config: %{"m" => 1}
    }

    assert P.harness_name(spec, nil) =~ ~r/^[a-zA-Z][a-zA-Z0-9_]{0,39}$/
  end

  test "a spec with no name at all still produces a valid name" do
    # Reachable only by calling harness_name/2 directly — provision/2 coerces through
    # Agent.Spec.new/1, which requires a binary name. It must still be legal for AWS.
    spec = %{system_prompt: "p", tools: [], terminal_tool: nil, model_config: %{"m" => 1}}

    assert P.harness_name(spec, nil) =~ ~r/^[a-zA-Z][a-zA-Z0-9_]{0,39}$/
  end

  test "harness_name/3 env-arg is nil-default and byte-identical to the 2-arg env-less name" do
    # The env-less path (no environment, or env == nil) MUST stay byte-identical to the
    # pre-#72 name so already-provisioned env-less harnesses keep their names on upgrade.
    base = %{system_prompt: "x", tools: [], model_config: %{"m" => 1}}
    assert P.harness_name(base, "t") == P.harness_name(base, "t", nil)
  end

  test "harness_name/3 folds the Environment.Spec digest in — different environments → different names (#70/#72)" do
    # Layer A of the collision fix: the SAME Agent.Spec content provisioned into DIFFERENT
    # environments must produce DIFFERENT harness names, so they don't clobber each other in
    # the Bedrock control plane. Environment now reaches naming only via the env arg — never
    # off the spec (Agent.Spec has no environment field).
    base = %{system_prompt: "x", tools: [], model_config: %{"m" => 1}}
    {:ok, env_a} = EnvSpec.new(%{config: %{environment: %{"a" => 1}}})
    {:ok, env_b} = EnvSpec.new(%{config: %{environment: %{"b" => 2}}})

    envless = P.harness_name(base, "t")

    # An env-bearing name differs from the env-less one...
    refute P.harness_name(base, "t", env_a) == envless
    # ...and two distinct environments differ from each other.
    refute P.harness_name(base, "t", env_a) == P.harness_name(base, "t", env_b)
  end

  test "harness_name/3 ignores the environment name (name excluded from the digest)" do
    base = %{system_prompt: "x", tools: [], model_config: %{"m" => 1}}
    {:ok, env1} = EnvSpec.new(%{name: "one", config: %{environment: %{"a" => 1}}})
    {:ok, env2} = EnvSpec.new(%{name: "two", config: %{environment: %{"a" => 1}}})

    assert P.harness_name(base, "t", env1) == P.harness_name(base, "t", env2)
  end

  # The live-canary shape (#70/#72 regression, fixed here): opts[:environment] is a bare
  # map whose only key is the AgentCore-specific "agentCoreRuntimeEnvironment" wrapper.
  # Environment.Spec.new/1 has no :name/:runtimes/:config key to match, so the WHOLE map
  # becomes env.config — this is exactly what build_spec/2 must hand to HarnessSpec.environment
  # verbatim (no indexing into it).
  @live_canary_env %{
    "agentCoreRuntimeEnvironment" => %{
      "filesystemConfigurations" => [%{"sessionStorage" => %{"mountPath" => "/mnt/data"}}]
    }
  }

  test "build_spec/2 maps opts[:environment]'s Environment.Spec.config to HarnessSpec.environment VERBATIM (#70/#72 fix)" do
    # Root cause of the regression: build_spec/2 used to index config[:environment], but
    # the config here IS the environment payload (no :environment key inside it) — so the
    # old code produced environment: nil and the harness got no /mnt/data mount. Bedrock
    # must be symmetric with ClaudeManagedAgents: config passes through untouched.
    spec = %{
      name: "env-harness",
      system_prompt: "x",
      tools: [],
      terminal_tool: nil,
      model_config: %{"m" => 1}
    }

    assert {:ok, %HarnessSpec{environment: env}} =
             P.build_spec(spec,
               execution_role_arn: "arn:aws:iam::1:role/r",
               environment: @live_canary_env
             )

    assert env == @live_canary_env
  end

  test "build_spec/2 with no opts[:environment] leaves HarnessSpec.environment nil" do
    spec = %{
      name: "env-less-harness",
      system_prompt: "x",
      tools: [],
      terminal_tool: nil,
      model_config: %{"m" => 1}
    }

    assert {:ok, %HarnessSpec{environment: nil}} =
             P.build_spec(spec, execution_role_arn: "arn:aws:iam::1:role/r")
  end

  test "provision/2 -> Client.create_harness wire body carries \"environment\" verbatim from opts[:environment] (#70/#72 fix)" do
    # End-to-end proof the fix reaches the wire: build_spec/2's HarnessSpec.environment,
    # signed and POSTed by the real AgentCore.Client, must carry the live-canary payload
    # under wire key "environment" byte-for-byte — this is what makes the
    # live_smoke_test.exs sessionStorage-mount case pass.
    bypass = Bypass.open()

    client =
      Client.new(
        credentials: %{
          access_key_id: "AKID",
          secret_access_key: "secret",
          region: "us-east-1",
          security_token: nil
        },
        base_url: "http://localhost:#{bypass.port}"
      )

    Bypass.expect_once(bypass, "POST", "/harnesses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["environment"] == @live_canary_env

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        ~s({"harness":{"arn":"arn:aws:bedrock-agentcore:us-east-1:1:harness/x","harnessId":"x-1","status":"CREATING"}})
      )
    end)

    spec = %{
      name: "env-harness",
      system_prompt: "x",
      tools: [],
      terminal_tool: nil,
      model_config: %{"m" => 1}
    }

    assert {:ok, %HarnessSpec{} = harness_spec} =
             P.build_spec(spec,
               execution_role_arn: "arn:aws:iam::1:role/r",
               environment: @live_canary_env
             )

    assert {:ok, _} = Client.create_harness(client, harness_spec)
  end
end
