defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.ProvisioningTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Agent.Spec
  alias ReqManagedAgents.Environment.Spec, as: EnvironmentSpec
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.{Client, Provisioning}
  alias ReqManagedAgents.Provisioner
  alias ReqManagedAgents.Provisioner.{Runtimes, Store}

  test "agent body renders only native fields with the reconciled name" do
    {:ok, spec} =
      Spec.new(%{
        name: "base",
        system_prompt: "system",
        model_config: %{id: "m"},
        tools: [%{name: "t"}],
        terminal_tool: "done"
      })

    assert Provisioning.agent_body(spec, "base_12345678") == %{
             name: "base_12345678",
             system: "system",
             model: %{id: "m"},
             tools: [%{name: "t"}]
           }
  end

  test "environment config merges runtime hosts and preserves native config" do
    {:ok, spec} =
      EnvironmentSpec.new(%{
        runtimes: [%{lang: :elixir, version: "1.17.0"}],
        config: %{
          type: :cloud,
          networking: %{"type" => "limited", "allowed_hosts" => ["example.test"]}
        }
      })

    config = Provisioning.environment_config(spec)

    assert config == %{
             type: :cloud,
             networking: %{
               "type" => "limited",
               "allowed_hosts" =>
                 Enum.uniq(["example.test" | Runtimes.required_hosts(spec.runtimes)])
             }
           }

    assert Provisioning.environment_config(%{spec | runtimes: []}) == spec.config
  end

  for client_module <- [Client, ReqManagedAgents.Client] do
    @client_module client_module
    test "#{inspect(client_module)} provisions, recovers a conflict and prunes through HTTP" do
      client = @client_module.new(api_key: "test", req_options: [plug: {Req.Test, __MODULE__}])
      {:ok, spec} = Spec.new(%{name: "agent", system_prompt: "system", model_config: "model"})
      name = "agent_" <> Spec.digest(spec)
      parent = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/v1/agents"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)

            assert Jason.decode!(body) == %{
                     "name" => name,
                     "system" => "system",
                     "model" => "model",
                     "tools" => []
                   }

            conn |> Plug.Conn.put_status(409) |> Req.Test.json(%{})

          {"GET", "/v1/agents"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{"id" => "live", "name" => name, "created_at" => "2026-02"},
                %{"id" => "old", "name" => "agent_00000000", "created_at" => "2026-01"}
              ]
            })

          {"POST", "/v1/agents/old/archive"} ->
            send(parent, :archived)
            Req.Test.json(conn, %{})
        end
      end)

      store = {Store.ETS, :"provider_provisioning_#{System.unique_integer([:positive])}"}

      assert {:ok, %{agent_id: "live", name: ^name}} =
               Provisioner.ensure_agent(client, spec, store: store)

      assert {:ok, %{archived: ["agent_00000000"], kept: [^name]}} =
               Provisioner.prune_agents(client, "agent", store: store, keep: 1)

      assert_received :archived
    end
  end

  for client_module <- [Client, ReqManagedAgents.Client] do
    @client_module client_module
    test "#{inspect(client_module)} ensures an environment with runtime config through HTTP" do
      client = @client_module.new(api_key: "test", req_options: [plug: {Req.Test, __MODULE__}])

      {:ok, spec} =
        EnvironmentSpec.new(%{
          runtimes: [%{lang: :elixir, version: "1.17.0"}],
          config: %{type: :cloud, networking: %{type: :limited, allowed_hosts: ["example.test"]}}
        })

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/environments"
        assert conn.method == "POST"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        wire = Jason.decode!(body)

        assert wire["config"]["networking"]["allowed_hosts"] ==
                 Enum.uniq(["example.test" | Runtimes.required_hosts(spec.runtimes)])

        refute Map.has_key?(wire["config"], "runtimes")
        Req.Test.json(conn, %{"id" => "env"})
      end)

      store = {Store.ETS, :"provider_environment_#{System.unique_integer([:positive])}"}

      assert {:ok, %{environment_id: "env", bootstrap: %{script: script}}} =
               Provisioner.ensure_environment(client, spec, store: store)

      assert script == Runtimes.bootstrap_script(spec.runtimes)
    end
  end

  test "provider environment operations preserve request paths and result tuples" do
    client = Client.new(api_key: "test", req_options: [plug: {Req.Test, __MODULE__}])

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/v1/environments"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body) == %{"name" => "env", "config" => %{"type" => "cloud"}}
          Req.Test.json(conn, %{"id" => "env"})

        {"GET", "/v1/environments"} ->
          Req.Test.json(conn, %{"data" => []})

        {"POST", "/v1/environments/env/archive"} ->
          conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad"})
      end
    end)

    assert {:ok, %{"id" => "env"}} =
             Provisioning.create_environment(client, %{name: "env", config: %{type: "cloud"}})

    assert {:ok, %{"data" => []}} = Provisioning.list_environments(client)

    assert {:error, {:http_error, 400, %{"error" => "bad"}}} =
             Provisioning.archive_environment(client, "env")
  end
end
