defmodule ReqManagedAgents.Providers.BedrockAgentCoreTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Agent.Spec
  alias ReqManagedAgents.AgentCore.Client
  alias ReqManagedAgents.Environment.Spec, as: EnvSpec
  alias ReqManagedAgents.Providers.BedrockAgentCore, as: P
  alias ReqManagedAgents.Providers.BedrockAgentCore.HarnessSpec
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

  defp prov_opts(create_fun, extra \\ []) do
    [
      execution_role_arn: "arn:aws:iam::1:role/R",
      create_fun: create_fun,
      get_fun: fn _hid -> {:ok, %{"harness" => %{"status" => "READY"}}} end
    ] ++ extra
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

    assert {:error, {:harness_still_deleting, ^name}} =
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
    # two computations MUST agree byte-for-byte, or an already-provisioned harness would
    # silently re-provision under a new name.
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
    assert P.harness_name(spec, nil) == "harness_#{new_digest}"
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
