defmodule ReqManagedAgents.SessionModelConfigTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.{FakeProviders, ModelConfig, Session}
  alias ReqManagedAgents.Providers.{BedrockAgentCore, ClaudeManagedAgents, Local}

  defmodule OpenProbe do
    @behaviour ReqManagedAgents.Provider

    @impl true
    def supports_runtime_model?, do: true
    @impl true
    def data_plane, do: :chat_completions
    @impl true
    def native_model("catalog:model"), do: {:ok, %{"modelId" => "native"}}
    def native_model(_other), do: :error
    @impl true
    def open(opts, _subscriber) do
      send(opts[:test], {:opened, opts[:model_config]})
      {:error, :probe_done}
    end

    @impl true
    defdelegate mode(), to: FakeProviders.RequestResponse
    @impl true
    defdelegate provision(spec, opts), to: FakeProviders.RequestResponse
    @impl true
    defdelegate kickoff_input(opts), to: FakeProviders.RequestResponse
    @impl true
    defdelegate user_input(text), to: FakeProviders.RequestResponse
    @impl true
    defdelegate resume_input(uses, results), to: FakeProviders.RequestResponse
    @impl true
    defdelegate normalize(events), to: FakeProviders.RequestResponse
    @impl true
    defdelegate session_id(conn), to: FakeProviders.RequestResponse
    @impl true
    defdelegate ref(conn), to: FakeProviders.RequestResponse
    @impl true
    defdelegate consumer(conn), to: FakeProviders.RequestResponse
    @impl true
    defdelegate resumed?(conn), to: FakeProviders.RequestResponse
  end

  @end_turn [%{"messageStop" => %{"stopReason" => "end_turn"}}]

  defp reporting_chat(test) do
    fn %{model: model} ->
      send(test, {:chat_model, model})

      {:ok,
       %{
         "choices" => [
           %{"message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}
         ]
       }}
    end
  end

  defp run_local(model_config) do
    Session.run(Local,
      handler: fn _, _, _ -> {:ok, ""} end,
      prompt: "hi",
      spec: %{system_prompt: "s"},
      chat_fun: reporting_chat(self()),
      model_config: model_config
    )
  end

  defp run_agentcore(invoke_fun, extra) do
    Session.run(
      BedrockAgentCore,
      [
        handler: fn _, _, _ -> {:ok, ""} end,
        prompt: "hi",
        harness_arn: "arn:new",
        runtime_session_id: String.duplicate("s", 33),
        invoke_fun: invoke_fun,
        timeout: 5_000
      ] ++ extra
    )
  end

  describe "the :model_config shape" do
    test "a string-keyed map is refused before the provider is called" do
      assert {:error, {:invalid_opts, {:model_config, {:unknown_keys, ["key", "model"]}}}} =
               run_local(%{"key" => "grant", "model" => "routed"})

      refute_received {:chat_model, _}
    end

    test "a canonical map delivers its model to the provider" do
      assert {:ok, _} = run_local(%{model: "routed", metadata: %{mimir_request_id: "r"}})
      assert_received {:chat_model, "routed"}
    end

    test "a keyword list and a struct are accepted" do
      assert {:ok, _} = run_local(model: "routed")
      assert_received {:chat_model, "routed"}

      {:ok, config} = ModelConfig.new(model: "routed")
      assert {:ok, _} = run_local(config)
      assert_received {:chat_model, "routed"}
    end

    test "nil means absent" do
      assert {:ok, _} = run_local(nil)
      assert_received {:chat_model, nil}
    end

    test "wrongly typed fields and non-map input are refused before open" do
      for {config, reason} <- [
            {%{api_key: false}, {:invalid, :api_key}},
            {%{metadata: false}, {:invalid, :metadata}},
            {"model", :not_a_map}
          ] do
        assert {:error, {:invalid_opts, {:model_config, ^reason}}} =
                 Session.run(OpenProbe, test: self(), model_config: config)
      end

      refute_received {:opened, _}
    end

    test "the provider receives a canonical map with translated model and retained metadata" do
      {:ok, config} =
        ModelConfig.new(model: "catalog:model", metadata: %{request_id: "request"})

      assert {:error, :probe_done} =
               Session.run(OpenProbe, test: self(), model_config: config)

      assert_received {:opened, rendered}
      assert rendered == %{model: %{"modelId" => "native"}, metadata: %{request_id: "request"}}

      assert {:error, :probe_done} =
               Session.run(OpenProbe,
                 test: self(),
                 model_config: %{model: %{"modelId" => "already-native"}}
               )

      assert_received {:opened, rendered}
      assert rendered == %{model: %{"modelId" => "already-native"}}
    end

    test "nil remains absent when starting a live session" do
      assert {:ok, pid} =
               Session.start_link(Local,
                 handler: fn _, _, _ -> {:ok, ""} end,
                 chat_fun: reporting_chat(self()),
                 model_config: nil,
                 notify: self()
               )

      Session.message(pid, "hi")

      assert_receive {:managed_agents_session,
                      %ReqManagedAgents.SessionResult{terminal: :end_turn}}

      assert_received {:chat_model, nil}
      GenServer.stop(pid)
    end

    test "a live session refuses it too" do
      Process.flag(:trap_exit, true)

      assert {:error, {:invalid_opts, {:model_config, {:unknown_keys, ["model"]}}}} =
               Session.start_link(Local,
                 handler: fn _, _, _ -> {:ok, ""} end,
                 chat_fun: reporting_chat(self()),
                 model_config: %{"model" => "m"}
               )
    end
  end

  describe "capabilities" do
    test "Claude Managed Agents refuses a per-run model before any request" do
      bypass = Bypass.open()
      test = self()

      Bypass.stub(bypass, "POST", "/v1/sessions", fn conn ->
        send(test, :cma_request)
        Plug.Conn.resp(conn, 400, "")
      end)

      assert {:error, :runtime_model_unsupported} =
               Session.run(ClaudeManagedAgents,
                 handler: fn _, _, _ -> {:ok, ""} end,
                 prompt: "hi",
                 agent_id: "agent",
                 environment_id: "env",
                 model_config: %{
                   model: "routed",
                   api_key: "grant",
                   base_url: "http://localhost:#{bypass.port}"
                 },
                 timeout: 5_000
               )

      refute_received :cma_request
    end

    test "Claude Managed Agents takes the credential and destination from model_config" do
      bypass = Bypass.open()
      test = self()

      Bypass.stub(bypass, "POST", "/v1/sessions", fn conn ->
        send(test, {:cma_key, Plug.Conn.get_req_header(conn, "x-api-key")})
        Plug.Conn.resp(conn, 400, "")
      end)

      assert {:error, {:create_session_failed, _}} =
               Session.run(ClaudeManagedAgents,
                 handler: fn _, _, _ -> {:ok, ""} end,
                 prompt: "hi",
                 agent_id: "agent",
                 environment_id: "env",
                 model_config: %{api_key: "grant", base_url: "http://localhost:#{bypass.port}"},
                 timeout: 5_000
               )

      assert_received {:cma_key, ["grant"]}
    end

    test "AgentCore refuses a credential or destination before invoking" do
      test = self()

      invoke_fun = fn _inv ->
        send(test, :invoked)
        {:ok, @end_turn}
      end

      for config <- [
            %{base_url: "http://127.0.0.1:9"},
            %{api_key: "grant"},
            %{bearer_token_file: "/dev/null"}
          ] do
        assert {:error, :data_plane_unsupported} =
                 run_agentcore(invoke_fun, model_config: config)
      end

      refute_received :invoked
    end

    test "an unsupported catalog id is refused before invoking AgentCore" do
      test = self()

      assert {:error, {:invalid_opts, {:model_config, {:unsupported_model, "openai:model"}}}} =
               run_agentcore(
                 fn _inv ->
                   send(test, :invoked)
                   {:ok, @end_turn}
                 end,
                 model_config: %{model: "openai:model"}
               )

      refute_received :invoked
    end

    test "Local refuses a bearer-token file it would silently drop" do
      assert {:error, :data_plane_unsupported} =
               run_local(%{bearer_token_file: "/dev/null", base_url: "http://127.0.0.1:9"})

      refute_received {:chat_model, _}
    end

    test "a provider declaring nothing refuses a model but accepts metadata alone" do
      assert {:error, :runtime_model_unsupported} =
               Session.run(FakeProviders.RequestResponse,
                 handler: fn _, _, _ -> {:ok, ""} end,
                 turns: [[%{"type" => "stop", "terminal" => :end_turn}]],
                 model_config: %{model: "m"}
               )

      assert {:ok, _} =
               Session.run(FakeProviders.RequestResponse,
                 handler: fn _, _, _ -> {:ok, ""} end,
                 turns: [[%{"type" => "stop", "terminal" => :end_turn}]],
                 model_config: %{metadata: %{mimir_request_id: "r"}}
               )
    end
  end
end
