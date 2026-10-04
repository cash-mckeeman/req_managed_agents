defmodule ReqManagedAgents.Host.ConfigTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Agent.Handle, as: AgentHandle
  alias ReqManagedAgents.Host.Config
  alias ReqManagedAgents.Provisioner.Environment.Handle, as: EnvironmentHandle

  defp valid_opts(overrides \\ []) do
    Keyword.merge(
      [provider: SomeProvider, handler: SomeHandler, store: {SomeStore, name: :store}],
      overrides
    )
  end

  test "new/1 with required fields returns {:ok, %Config{}} with default timeouts" do
    assert {:ok,
            %Config{
              provider: SomeProvider,
              handler: SomeHandler,
              store: {SomeStore, name: :store},
              idle_timeout_ms: 300_000,
              timeout_ms: 600_000
            }} = Config.new(valid_opts())
  end

  test "new/1 without :provider returns {:error, {:invalid_config, :provider}}" do
    opts = valid_opts() |> Keyword.delete(:provider)
    assert {:error, {:invalid_config, :provider}} = Config.new(opts)
  end

  test "new/1 with :provider set to nil returns {:error, {:invalid_config, :provider}}" do
    assert {:error, {:invalid_config, :provider}} = Config.new(valid_opts(provider: nil))
  end

  test "new/1 without :handler returns {:error, {:invalid_config, :handler}}" do
    opts = valid_opts() |> Keyword.delete(:handler)
    assert {:error, {:invalid_config, :handler}} = Config.new(opts)
  end

  test "new/1 without :store returns {:error, {:invalid_config, :store}}" do
    opts = valid_opts() |> Keyword.delete(:store)
    assert {:error, {:invalid_config, :store}} = Config.new(opts)
  end

  test "new/1 carries an %Agent.Handle{} passed as :agent" do
    handle = %AgentHandle{agent_id: "agent-1", name: "reviewer", digest: "sha256:abc"}

    assert {:ok, %Config{agent: ^handle}} = Config.new(valid_opts(agent: handle))
  end

  test "new/1 carries an %Environment.Handle{} passed as :environment" do
    handle = %EnvironmentHandle{environment_id: "env-1", name: "sandbox", digest: "sha256:def"}

    assert {:ok, %Config{environment: ^handle}} = Config.new(valid_opts(environment: handle))
  end

  test "new/1 accepts overrides for idle_timeout_ms, timeout_ms, metadata, provider_opts" do
    assert {:ok,
            %Config{
              idle_timeout_ms: 1_000,
              timeout_ms: 2_000,
              metadata: %{env: "test"},
              provider_opts: [base_url: "http://localhost"]
            }} =
             Config.new(
               valid_opts(
                 idle_timeout_ms: 1_000,
                 timeout_ms: 2_000,
                 metadata: %{env: "test"},
                 provider_opts: [base_url: "http://localhost"]
               )
             )
  end
end
