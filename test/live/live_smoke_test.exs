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

  @tag timeout: 120_000
  test "full cycle against the live beta" do
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)
    client = ReqManagedAgents.new()

    {:ok, %{"id" => env_id}} =
      ReqManagedAgents.Client.create_environment(client, %{
        name: "req-managed-agents-live-smoke",
        config: %{type: "cloud", networking: %{type: "unrestricted"}}
      })

    {:ok, %{"id" => agent_id}} =
      ReqManagedAgents.Client.create_agent(client, %{
        name: "req-managed-agents-live-smoke",
        model: "claude-opus-4-8",
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

    assert_receive {:managed_agents_session, %ReqManagedAgents.SessionResult{terminal: :end_turn}}, 90_000
  end

  @tag timeout: 120_000
  test "run_to_completion drives the full cycle against the live beta" do
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)
    client = ReqManagedAgents.new()

    {:ok, %{"id" => env_id}} =
      ReqManagedAgents.Client.create_environment(client, %{
        name: "rma-v02-rtc",
        config: %{type: "cloud", networking: %{type: "unrestricted"}}
      })

    {:ok, %{"id" => agent_id}} =
      ReqManagedAgents.Client.create_agent(client, %{
        name: "rma-v02-rtc",
        model: "claude-opus-4-8",
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
        is_map(e) and (e["type"] == "span.model_request_end" or Map.has_key?(e, "model_usage") or Map.has_key?(e, "usage"))
      end)

    IO.inspect(usage_events, label: "LIVE usage-bearing events (confirm the shape)", limit: :infinity, printable_limit: :infinity)
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
        model: "claude-opus-4-8",
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
end
