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

    assert_receive {:managed_agents_session, :end_turn}, 90_000
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

    assert {:ok, %{terminal: :end_turn}} =
             ReqManagedAgents.run_to_completion(
               client: client,
               agent_id: agent_id,
               environment_id: env_id,
               prompt: "Please echo: hi-rtc",
               handler: Handler,
               timeout: 90_000
             )
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
