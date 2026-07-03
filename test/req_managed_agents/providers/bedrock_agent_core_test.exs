defmodule ReqManagedAgents.Providers.BedrockAgentCoreTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Providers.BedrockAgentCore, as: P
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

  test "MIM-52 regression: a reused contentBlockIndex recovers BOTH distinct tools" do
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

  test "kickoff_input/1 and user_input/1 build user messages" do
    assert P.kickoff_input(prompt: "go") == [
             %{"role" => "user", "content" => [%{"text" => "go"}]}
           ]

    assert P.user_input("hi") == [%{"role" => "user", "content" => [%{"text" => "hi"}]}]
  end

  test "resume_input/2 produces the strict two-message delta" do
    uses = [%{id: "tu_1", name: "echo", input: %{"text" => "hi"}}]
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

  @spec_bedrock %{
    system_prompt: "be helpful",
    tools: [%{"name" => "t"}],
    terminal_tool: nil,
    model_config: %{"bedrockModelConfig" => %{"modelId" => "anthropic.claude-sonnet-4"}}
  }

  defp prov_opts(create_fun, extra \\ []) do
    [
      execution_role_arn: "arn:aws:iam::1:role/R",
      create_fun: create_fun,
      get_fun: fn _hid -> {:ok, %{"harness" => %{"status" => "READY"}}} end
    ] ++ extra
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
               ready_poll_ms: 0
             )
  end

  test "provision/2 surfaces a CREATE_FAILED harness" do
    create = fn _ -> {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "h"}}} end
    get = fn _ -> {:ok, %{"harness" => %{"status" => "CREATE_FAILED"}}} end

    assert {:error, {:harness_failed, "CREATE_FAILED"}} =
             P.provision(@spec_bedrock,
               execution_role_arn: "r",
               create_fun: create,
               get_fun: get,
               ready_poll_ms: 0
             )
  end

  test "provision/2 times out if the harness never becomes READY" do
    create = fn _ -> {:ok, %{"harness" => %{"arn" => "a", "harnessId" => "h"}}} end
    get = fn _ -> {:ok, %{"harness" => %{"status" => "CREATING"}}} end

    assert {:error, :harness_ready_timeout} =
             P.provision(@spec_bedrock,
               execution_role_arn: "r",
               create_fun: create,
               get_fun: get,
               ready_poll_ms: 0,
               ready_max_polls: 2
             )
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

  # ── MIM-50 long-run threading ─────────────────────────────────────────────────

  describe "MIM-50 long-run threading" do
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

  test "provision threads environment fields into the harness spec, and the spec-hash covers them" do
    base = %{system_prompt: "x", tools: [], model_config: %{"m" => 1}}

    with_env =
      Map.merge(base, %{
        environment: %{
          "agentCoreRuntimeEnvironment" => %{
            "filesystemConfigurations" => [%{"sessionStorage" => %{"mountPath" => "/mnt/data"}}]
          }
        },
        environment_variables: %{"A" => "1"}
      })

    # Differently-mounted specs must provision under different deterministic names —
    # otherwise they'd collide in the Provisioner cache.
    refute P.harness_name(base, "t") == P.harness_name(with_env, "t")

    test_pid = self()

    create_fun = fn harness_spec ->
      send(test_pid, {:harness_spec, harness_spec})

      {:ok,
       %{
         "harness" => %{
           "arn" => "arn:aws:bedrock-agentcore:us-east-1:1:harness/x",
           "harnessId" => "x"
         }
       }}
    end

    get_fun = fn _ -> {:ok, %{"harness" => %{"status" => "READY"}}} end

    assert {:ok, _} =
             P.provision(with_env,
               execution_role_arn: "arn:aws:iam::1:role/r",
               create_fun: create_fun,
               get_fun: get_fun
             )

    assert_received {:harness_spec, hs}
    assert hs.environment == with_env.environment
    assert hs.environment_variables == %{"A" => "1"}
  end
end
