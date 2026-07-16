defmodule ReqManagedAgents.LiveSmokeTest do
  use ExUnit.Case
  @moduletag :live

  defmodule Handler do
    @behaviour ReqManagedAgents.Handler
    @impl true
    def handle_tool_call("echo", %{"text" => text}, _ctx), do: {:ok, "you said: #{text}"}
    @impl true
    def handle_event(_ev, _ctx), do: :ok
  end

  @canary_env_spec %{type: "cloud", networking: %{type: "unrestricted"}}

  @tag timeout: 120_000
  test "full cycle against the live beta" do
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)
    client = ReqManagedAgents.new()

    {:ok, %{environment_id: env_id}} =
      ReqManagedAgents.ensure_environment(client, @canary_env_spec, name: "rma_canary")

    {:ok, %{"id" => agent_id}} =
      ReqManagedAgents.Client.create_agent(client, %{
        name: "req-managed-agents-live-smoke",
        model: System.get_env("CMA_LIVE_MODEL", "claude-haiku-4-5"),
        system: "When asked to echo, call the echo tool with the user's text.",
        tools: [
          %{
            type: "custom",
            name: "echo",
            description: "Echo the user's text back. Always use this to echo.",
            input_schema: %{
              "type" => "object",
              "properties" => %{"text" => %{"type" => "string"}},
              "required" => ["text"]
            }
          }
        ]
      })

    {:ok, _pid} =
      ReqManagedAgents.start_session(
        client: client,
        agent_id: agent_id,
        environment_id: env_id,
        prompt: "Please echo: hello-managed-agents",
        handler: Handler,
        notify: self()
      )

    assert_receive {:managed_agents_session,
                    %ReqManagedAgents.SessionResult{terminal: :end_turn}},
                   90_000
  end

  @tag timeout: 120_000
  test "run_to_completion drives the full cycle against the live beta" do
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)
    client = ReqManagedAgents.new()

    {:ok, %{environment_id: env_id}} =
      ReqManagedAgents.ensure_environment(client, @canary_env_spec, name: "rma_canary")

    {:ok, %{"id" => agent_id}} =
      ReqManagedAgents.Client.create_agent(client, %{
        name: "rma-v02-rtc",
        model: System.get_env("CMA_LIVE_MODEL", "claude-haiku-4-5"),
        system: "When asked to echo, call the echo tool with the user's text.",
        tools: [
          %{
            type: "custom",
            name: "echo",
            description: "Echo the user's text back. Always use this to echo.",
            input_schema: %{
              "type" => "object",
              "properties" => %{"text" => %{"type" => "string"}},
              "required" => ["text"]
            }
          }
        ]
      })

    assert {:ok, %ReqManagedAgents.SessionResult{terminal: :end_turn} = result} =
             ReqManagedAgents.run_to_completion(
               client: client,
               agent_id: agent_id,
               environment_id: env_id,
               prompt: "Please echo: hi-rtc",
               handler: Handler,
               timeout: 90_000
             )

    # THE real test for usage: confirm the reconciled wire-shape against the live beta.
    # Dump every event that could carry usage so we can eyeball the actual shape
    # (we reconciled it as `span.model_request_end` → `model_usage`, not first-hand).
    usage_events =
      Enum.filter(result.events, fn e ->
        is_map(e) and
          (e["type"] == "span.model_request_end" or Map.has_key?(e, "model_usage") or
             Map.has_key?(e, "usage"))
      end)

    IO.inspect(usage_events,
      label: "LIVE usage-bearing events (confirm the shape)",
      limit: :infinity,
      printable_limit: :infinity
    )

    IO.inspect(result.usage, label: "LIVE SessionResult.usage")

    assert %ReqManagedAgents.Usage{input_tokens: input, output_tokens: output} = result.usage,
           "expected a %Usage{} on the live result, got: #{inspect(result.usage)}"

    assert input > 0 and output > 0,
           "expected non-zero live token usage (our Claude usage wire-shape may be wrong) — got #{inspect(result.usage)}; raw usage events: #{inspect(usage_events)}"
  end

  @tag timeout: 60_000
  test "list_environments returns a data envelope" do
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)
    client = ReqManagedAgents.new()
    assert {:ok, %{"data" => envs}} = ReqManagedAgents.Client.list_environments(client)
    assert is_list(envs)
  end

  @tag timeout: 60_000
  @tag :live_files
  test "file upload -> attach to a session" do
    # Note: a `purpose: "agent"` file is an INPUT for the agent, not retrievable
    # via the content endpoint (the API returns "File ... is not downloadable").
    # download_file/2's wire behavior is covered by the unit suite; here we prove
    # the live write path: upload then attach to a session.
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)
    client = ReqManagedAgents.new()

    {:ok, %{"id" => file_id}} =
      ReqManagedAgents.Client.upload_file(client, %{
        purpose: "agent",
        file: {"note.txt", "hello-from-test"}
      })

    {:ok, %{"id" => env_id}} =
      ReqManagedAgents.Client.create_environment(client, %{
        name: "rma-v02-file",
        config: %{type: "cloud", networking: %{type: "unrestricted"}}
      })

    # File resources require the session's agent to have a built-in toolset with
    # the `read` tool enabled, so declare the built-in agent toolset here.
    {:ok, %{"id" => agent_id}} =
      ReqManagedAgents.Client.create_agent(client, %{
        name: "rma-v02-file",
        model: System.get_env("CMA_LIVE_MODEL", "claude-haiku-4-5"),
        system: "x",
        tools: [%{type: "agent_toolset_20260401"}]
      })

    {:ok, %{"id" => session_id}} =
      ReqManagedAgents.Client.create_session(client, %{agent: agent_id, environment_id: env_id})

    assert {:ok, _resource} =
             ReqManagedAgents.Client.attach_file_to_session(client, session_id, %{
               file_id: file_id,
               mount_path: "/data/note.txt"
             })
  end

  @tag timeout: 180_000
  @tag :live_cma_provision
  test "Claude Managed Agents: provision → run → teardown (provider-agnostic seam, live)" do
    alias ReqManagedAgents.Providers.ClaudeManagedAgents
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)
    client = ReqManagedAgents.new()

    # Mirrors the Bedrock leg below on the SAME canonical spec shape —
    # `model_config` is the opaque provider-native blob (for Claude: the model
    # id string that lands on the agent's `model` field). This is the live
    # proof for `ClaudeManagedAgents.provision/2` + `teardown/2`, which the
    # unit suite covers only against stubs.
    spec = %{
      name: "rma-live-cma-provision",
      system_prompt: "When asked to echo, call the echo tool with the user's text.",
      terminal_tool: nil,
      model_config: System.get_env("CMA_LIVE_MODEL", "claude-haiku-4-5"),
      tools: [
        %{
          type: "custom",
          name: "echo",
          description: "Echo the user's text back. Always use this to echo.",
          input_schema: %{
            "type" => "object",
            "properties" => %{"text" => %{"type" => "string"}},
            "required" => ["text"]
          }
        }
      ]
    }

    {:ok, handle} =
      ReqManagedAgents.provision(ClaudeManagedAgents, spec,
        client: client,
        name: "rma-live-cma-provision"
      )

    IO.inspect(handle, label: "LIVE CMA provisioned handle")
    assert %{agent_id: _, environment_id: _} = handle

    try do
      assert {:ok, %ReqManagedAgents.SessionResult{terminal: :end_turn} = result} =
               ReqManagedAgents.Session.run(ClaudeManagedAgents,
                 client: client,
                 agent_id: handle.agent_id,
                 environment_id: handle.environment_id,
                 prompt: "Please echo: hello-provisioned",
                 handler: Handler,
                 timeout: 120_000
               )

      IO.inspect(result.usage, label: "LIVE CMA provisioned-run usage")
    after
      # Claude archives are synchronous (and permanent), so unlike the async
      # Bedrock delete below we can assert teardown/2 live.
      assert :ok = ReqManagedAgents.teardown(ClaudeManagedAgents, handle, client: client)
    end
  end

  @tag timeout: 600_000
  @tag :live_bedrock
  @tag skip:
         if(System.get_env("HARNESS_EXECUTION_ROLE_ARN") in [nil, ""],
           do: "requires HARNESS_EXECUTION_ROLE_ARN (AWS harness execution role ARN)",
           else: false
         )
  test "AgentCore Harness: provision → invoke → live usage → teardown" do
    alias ReqManagedAgents.Providers.BedrockAgentCore
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)

    role = System.fetch_env!("HARNESS_EXECUTION_ROLE_ARN")

    spec = %{
      name: "rma-live-bedrock-harness",
      system_prompt: "You are a terse assistant. Reply in a few words.",
      tools: [],
      terminal_tool: nil,
      model_config: %{
        "bedrockModelConfig" => %{
          "modelId" => System.get_env("BEDROCK_LIVE_MODEL_ID", "nvidia.nemotron-super-3-120b")
        }
      }
    }

    {:ok, handle} =
      ReqManagedAgents.provision(BedrockAgentCore, spec,
        execution_role_arn: role,
        name_prefix: "rma_live"
      )

    IO.inspect(handle, label: "LIVE Bedrock provisioned handle")

    try do
      {:ok, %ReqManagedAgents.SessionResult{terminal: :end_turn} = result} =
        ReqManagedAgents.AgentCore.invoke_to_completion(
          harness_arn: handle.harness_arn,
          runtime_session_id:
            "live-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
          prompt: "Reply with exactly: hello there",
          handler: Handler,
          # Exercise the per-invocation server budgets + a generous idle guard
          # against a real harness — validates the overrides are accepted on the wire
          # and that the 300s idle floor holds during server-side tool execution.
          idle_timeout: 300_000,
          timeout_seconds: 900,
          max_iterations: 40,
          timeout: 300_000
        )

      metadata_events = Enum.filter(result.events, &(is_map(&1) and Map.has_key?(&1, "metadata")))

      IO.inspect(metadata_events,
        label: "LIVE Bedrock metadata/usage events",
        limit: :infinity,
        printable_limit: :infinity
      )

      IO.inspect(result.usage, label: "LIVE Bedrock SessionResult.usage")

      assert %ReqManagedAgents.Usage{input_tokens: i, output_tokens: o} = result.usage,
             "expected %Usage{} on the live Bedrock result, got: #{inspect(result.usage)}"

      assert i > 0 and o > 0,
             "expected non-zero live Bedrock usage (does AgentCore emit metadata.usage?) — got #{inspect(result.usage)}"
    after
      IO.inspect(ReqManagedAgents.teardown(BedrockAgentCore, handle),
        label: "LIVE Bedrock teardown"
      )
    end
  end

  # THE OUTPUTS-DIR CONVENTION (established live, 2026-07-03, four probe
  # rounds): only files written under /mnt/session/outputs/ become session
  # artifacts — scoped to the session (`scope_id`), `downloadable: true`, and
  # carrying a `scope` object. Files written elsewhere (e.g. /workspace) leave
  # non-downloadable, unscoped residue. Prompts/system prompts must direct
  # deliverables to /mnt/session/outputs/.
  @tag timeout: 240_000
  test "CMA artifacts: agent writes a file → Artifacts list/fetch/delete round-trip" do
    alias ReqManagedAgents.Artifacts
    alias ReqManagedAgents.Artifacts.ClaudeFiles
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)
    client = ReqManagedAgents.new()

    {:ok, %{environment_id: env_id}} =
      ReqManagedAgents.ensure_environment(client, @canary_env_spec, name: "rma_canary")

    # The built-in toolset provides the `write` tool the agent needs.
    {:ok, %{"id" => agent_id}} =
      ReqManagedAgents.Client.create_agent(client, %{
        name: "rma-v03-artifacts",
        model: System.get_env("CMA_LIVE_MODEL", "claude-haiku-4-5"),
        system:
          "When asked to save a note, write EXACTLY the requested text to the requested " <>
            "absolute path, then stop.",
        tools: [%{type: "agent_toolset_20260401"}]
      })

    assert {:ok, %ReqManagedAgents.SessionResult{terminal: :end_turn, session_id: session_id}} =
             ReqManagedAgents.run_to_completion(
               client: client,
               agent_id: agent_id,
               environment_id: env_id,
               prompt:
                 "Save a note: write the text 'artifact-canary-ok' to " <>
                   ClaudeFiles.output_path("note.txt"),
               handler: Handler,
               timeout: 180_000
             )

    assert is_binary(session_id)
    store = {ClaudeFiles, ClaudeFiles.store(client, session_id)}

    # Registration into the scoped list can lag the write briefly — poll.
    artifacts =
      Enum.reduce_while(1..12, [], fn attempt, _acc ->
        {:ok, artifacts} = Artifacts.list(store)

        if Enum.any?(artifacts, &(&1.name == "note.txt")) do
          {:halt, artifacts}
        else
          Process.sleep(5_000)
          if attempt == 12, do: {:halt, artifacts}, else: {:cont, artifacts}
        end
      end)

    IO.inspect(artifacts, label: "LIVE CMA artifacts")
    assert Enum.any?(artifacts, &(&1.name == "note.txt"))

    assert {:ok, bytes} = Artifacts.fetch(store, "note.txt")
    assert bytes =~ "artifact-canary-ok"

    assert :ok = Artifacts.delete(store, "note.txt")
  end

  @tag timeout: 600_000
  @tag :live_bedrock_command
  @tag skip:
         if(System.get_env("HARNESS_EXECUTION_ROLE_ARN") in [nil, ""],
           do: "requires HARNESS_EXECUTION_ROLE_ARN (AWS harness execution role ARN)",
           else: false
         )
  test "AgentCore command: exec into the session microVM — stdout, stderr, exit codes" do
    alias ReqManagedAgents.AgentCore.{Client, CommandResult}
    alias ReqManagedAgents.Providers.BedrockAgentCore
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)

    role = System.fetch_env!("HARNESS_EXECUTION_ROLE_ARN")

    spec = %{
      name: "rma-live-bedrock-command",
      system_prompt: "You are a terse assistant.",
      tools: [],
      terminal_tool: nil,
      model_config: %{
        "bedrockModelConfig" => %{
          "modelId" => System.get_env("BEDROCK_LIVE_MODEL_ID", "nvidia.nemotron-super-3-120b")
        }
      }
    }

    {:ok, handle} =
      ReqManagedAgents.provision(BedrockAgentCore, spec,
        execution_role_arn: role,
        name_prefix: "rma_live"
      )

    try do
      client = Client.new()
      sid = "live-cmd-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      assert {:ok, %CommandResult{exit_code: 0} = ok} =
               Client.invoke_agent_runtime_command(client, %{
                 agent_runtime_arn: handle.harness_arn,
                 runtime_session_id: sid,
                 command: "echo canary-stdout && echo canary-stderr 1>&2"
               })

      IO.inspect(ok, label: "LIVE command result")
      assert ok.stdout =~ "canary-stdout"
      assert ok.stderr =~ "canary-stderr"

      assert {:ok, %CommandResult{exit_code: 7}} =
               Client.invoke_agent_runtime_command(client, %{
                 agent_runtime_arn: handle.harness_arn,
                 runtime_session_id: sid,
                 command: "exit 7"
               })
    after
      IO.inspect(ReqManagedAgents.teardown(BedrockAgentCore, handle),
        label: "LIVE command-leg teardown"
      )
    end
  end

  @tag timeout: 600_000
  @tag :live_bedrock_mount
  @tag skip:
         if(System.get_env("HARNESS_EXECUTION_ROLE_ARN") in [nil, ""],
           do: "requires HARNESS_EXECUTION_ROLE_ARN (AWS harness execution role ARN)",
           else: false
         )
  test "AgentCore sessionStorage mount: environment pass-through + Artifacts put/fetch round-trip" do
    alias ReqManagedAgents.Artifacts
    alias ReqManagedAgents.Artifacts.AgentCoreSessionStorage
    alias ReqManagedAgents.Providers.BedrockAgentCore
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)

    role = System.fetch_env!("HARNESS_EXECUTION_ROLE_ARN")

    spec = %{
      name: "rma-live-bedrock-mount",
      system_prompt: "You are a terse assistant.",
      tools: [],
      terminal_tool: nil,
      model_config: %{
        "bedrockModelConfig" => %{
          "modelId" => System.get_env("BEDROCK_LIVE_MODEL_ID", "nvidia.nemotron-super-3-120b")
        }
      }
    }

    # The opaque environment pass-through, sessionStorage = the no-VPC mount. Relocated to
    # opts (#70) — Agent.Spec.new/1's boundary coercion drops any non-Spec key, so this can
    # no longer live on the spec map.
    environment = %{
      "agentCoreRuntimeEnvironment" => %{
        "filesystemConfigurations" => [%{"sessionStorage" => %{"mountPath" => "/mnt/data"}}]
      }
    }

    {:ok, handle} =
      ReqManagedAgents.provision(BedrockAgentCore, spec,
        execution_role_arn: role,
        name_prefix: "rma_live",
        environment: environment
      )

    try do
      client = ReqManagedAgents.AgentCore.Client.new()
      sid = "live-mnt-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      store =
        {AgentCoreSessionStorage,
         AgentCoreSessionStorage.store(client, handle.harness_arn, sid, "/mnt/data")}

      contents = "mount-canary " <> Base.encode64(:crypto.strong_rand_bytes(64))
      assert :ok = Artifacts.put(store, "canary.txt", contents)

      {:ok, listed} = Artifacts.list(store)
      IO.inspect(listed, label: "LIVE mount artifacts")
      assert Enum.any?(listed, &(&1.name == "canary.txt"))

      assert {:ok, ^contents} = Artifacts.fetch(store, "canary.txt")
      assert :ok = Artifacts.delete(store, "canary.txt")
    after
      IO.inspect(ReqManagedAgents.teardown(BedrockAgentCore, handle),
        label: "LIVE mount-leg teardown"
      )
    end
  end

  @tag timeout: 240_000
  @tag :live_env_images
  test "image lifecycle: ensure reuse, tag/resolve, run on resolved env, prune" do
    alias ReqManagedAgents.Provisioner
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)
    client = ReqManagedAgents.new()

    # Two consecutive ensure_environment calls with the SAME spec must hit the
    # ETS store on the second call and return the identical environment_id.
    {:ok, %{environment_id: env_id_1} = handle} =
      ReqManagedAgents.ensure_environment(client, @canary_env_spec, name: "rma_canary")

    {:ok, %{environment_id: env_id_2}} =
      ReqManagedAgents.ensure_environment(client, @canary_env_spec, name: "rma_canary")

    assert env_id_1 == env_id_2,
           "ensure_environment must return the same environment_id on a store hit"

    # Tag the current image and resolve it back — the returned handle must
    # point at the same environment.
    :ok = Provisioner.tag("rma_canary", "current", handle)
    {:ok, resolved} = Provisioner.resolve("rma_canary:current")
    assert resolved.environment_id == env_id_1

    # Run a session on the resolved environment to prove it is usable.
    {:ok, %{"id" => agent_id}} =
      ReqManagedAgents.Client.create_agent(client, %{
        name: "rma-v04-image-run",
        model: System.get_env("CMA_LIVE_MODEL", "claude-haiku-4-5"),
        system: "When asked to echo, call the echo tool with the user's text.",
        tools: [
          %{
            type: "custom",
            name: "echo",
            description: "Echo the user's text back. Always use this to echo.",
            input_schema: %{
              "type" => "object",
              "properties" => %{"text" => %{"type" => "string"}},
              "required" => ["text"]
            }
          }
        ]
      })

    assert {:ok, %ReqManagedAgents.SessionResult{terminal: :end_turn}} =
             ReqManagedAgents.run_to_completion(
               client: client,
               agent_id: agent_id,
               environment_id: resolved.environment_id,
               prompt: "Please echo: image-canary-ok",
               handler: Handler,
               timeout: 180_000
             )

    # Prune: keep 2 — the currently-ensured name must never appear in archived,
    # and the tagged digest's name must appear in kept. Self-cleaning: superseded
    # generations from past runs are archived.
    {:ok, %{archived: archived, kept: kept}} =
      Provisioner.prune_environments(client, "rma_canary", keep: 2)

    IO.inspect(%{archived: archived, kept: kept}, label: "LIVE prune result")

    assert handle.name in kept,
           "the currently-ensured env (#{handle.name}) must be in kept, not pruned"

    refute handle.name in archived,
           "the currently-ensured env (#{handle.name}) must NOT appear in archived"
  end

  @tag timeout: 420_000
  @tag :live_runtime
  test "runtime bootstrap: ensure env with runtimes, agent executes bootstrap, elixir version confirmed" do
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)
    client = ReqManagedAgents.new()

    runtime_spec =
      Map.put(@canary_env_spec, :runtimes, [
        %{lang: :erlang, version: "29.0.2", via: :mise},
        %{lang: :elixir, version: "1.20.2", via: :mise}
      ])

    {:ok, %{environment_id: env_id, bootstrap: %{instructions: instructions}}} =
      ReqManagedAgents.ensure_environment(client, runtime_spec, name: "rma_canary_rt")

    {:ok, %{"id" => agent_id}} =
      ReqManagedAgents.Client.create_agent(client, %{
        name: "rma-v04-runtime",
        model: System.get_env("CMA_LIVE_MODEL", "claude-sonnet-4-6"),
        system: instructions <> "\nYou execute exactly what the user asks.",
        tools: [%{type: "agent_toolset_20260401"}]
      })

    assert {:ok, %ReqManagedAgents.SessionResult{terminal: :end_turn} = result} =
             ReqManagedAgents.run_to_completion(
               client: client,
               agent_id: agent_id,
               environment_id: env_id,
               prompt:
                 "First run the bootstrap exactly once as instructed, then run: " <>
                   "elixir -e 'IO.puts(\"rt-canary:\" <> System.version())' and paste its full output.",
               handler: Handler,
               timeout: 400_000
             )

    IO.inspect(result.text, label: "LIVE runtime result text")

    assert result.text =~ "rt-canary:1.20",
           "expected 'rt-canary:1.20' in agent output, got: #{inspect(result.text)}"
  end

  @tag timeout: 300_000
  test "AgentCore Harness: within-window reattach via session_id: continues the conversation" do
    alias ReqManagedAgents.Providers.BedrockAgentCore
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)

    role = System.fetch_env!("HARNESS_EXECUTION_ROLE_ARN")

    spec = %{
      name: "rma-live-bedrock-reattach",
      system_prompt: "You are a terse assistant. Reply in a few words.",
      tools: [],
      terminal_tool: nil,
      model_config: %{
        "bedrockModelConfig" => %{
          "modelId" => System.get_env("BEDROCK_LIVE_MODEL_ID", "nvidia.nemotron-super-3-120b")
        }
      }
    }

    {:ok, handle} =
      ReqManagedAgents.provision(BedrockAgentCore, spec,
        execution_role_arn: role,
        name_prefix: "rma_live"
      )

    sid = "live-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    common = [
      harness_arn: handle.harness_arn,
      handler: Handler,
      idle_timeout: 300_000,
      timeout_seconds: 900,
      max_iterations: 40,
      timeout: 300_000
    ]

    try do
      {:ok, %ReqManagedAgents.SessionResult{terminal: :end_turn}} =
        ReqManagedAgents.AgentCore.invoke_to_completion(
          [
            runtime_session_id: sid,
            prompt: "Remember this codeword: quokka. Acknowledge with OK."
          ] ++ common
        )

      # Within the session window (seconds later): reattach with the RMA-canonical
      # session_id: — the 0.10 reattach path (open/2 targets the EXISTING runtime
      # session, resumed?/1 true, :resume rides the reconnect safe-default, and the
      # prompt is delivered via the #66 seam). Recall proves server-side continuity.
      {:ok, %ReqManagedAgents.SessionResult{terminal: :end_turn, text: text} = r2} =
        ReqManagedAgents.AgentCore.invoke_to_completion(
          [
            session_id: sid,
            prompt: "What was the codeword? Reply with just the codeword."
          ] ++ common
        )

      IO.inspect(text, label: "LIVE Bedrock reattach recall")

      assert text =~ ~r/quokka/i,
             "expected the reattached session to recall the codeword — got: #{inspect(text)}"

      assert r2.session_id == sid
    after
      IO.inspect(ReqManagedAgents.teardown(BedrockAgentCore, handle),
        label: "LIVE Bedrock reattach teardown"
      )
    end
  end
end
