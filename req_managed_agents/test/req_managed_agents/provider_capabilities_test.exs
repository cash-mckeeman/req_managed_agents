defmodule ReqManagedAgents.ProviderCapabilitiesTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.{FakeProviders, Provider}
  alias ReqManagedAgents.Providers.{BedrockAgentCore, ClaudeManagedAgents, Local}

  @declared [
    {Local, runtime_model: true, data_plane: true, budget: false, outcomes: false},
    {ClaudeManagedAgents, runtime_model: false, data_plane: true, budget: true, outcomes: true},
    {BedrockAgentCore, runtime_model: true, data_plane: false, budget: false, outcomes: false}
  ]

  for {provider, expected} <- @declared do
    test "#{inspect(provider)} declares #{inspect(expected)}" do
      for {capability, value} <- unquote(expected) do
        assert Provider.supports?(unquote(provider), capability) == value, inspect(capability)
      end
    end
  end

  test "a provider without the optional callbacks supports none of them" do
    for capability <- [:outcomes, :budget, :runtime_model, :data_plane] do
      refute Provider.supports?(FakeProviders.RequestResponse, capability)
    end
  end

  test "each provider names its data-plane wire" do
    assert Provider.data_plane(Local) == :chat_completions
    assert Provider.data_plane(ClaudeManagedAgents) == :managed_agents_api
    assert Provider.data_plane(BedrockAgentCore) == :none
    assert Provider.data_plane(FakeProviders.RequestResponse) == :none
  end

  describe "native_model/2: catalog model id to wire model value" do
    test "Claude Managed Agents takes an anthropic catalog id as its bare model id" do
      assert Provider.native_model(ClaudeManagedAgents, "anthropic:claude-haiku-4-5") ==
               {:ok, "claude-haiku-4-5"}

      assert Provider.native_model(ClaudeManagedAgents, "bedrock:us.anthropic.claude-sonnet-4-6") ==
               {:error, {:unsupported_model, "bedrock:us.anthropic.claude-sonnet-4-6"}}
    end

    test "AgentCore takes a bedrock catalog id as its bedrockModelConfig union" do
      assert Provider.native_model(BedrockAgentCore, "bedrock:us.anthropic.claude-sonnet-4-6") ==
               {:ok, %{"bedrockModelConfig" => %{"modelId" => "us.anthropic.claude-sonnet-4-6"}}}

      assert Provider.native_model(BedrockAgentCore, "anthropic:claude-haiku-4-5") ==
               {:error, {:unsupported_model, "anthropic:claude-haiku-4-5"}}
    end

    test "empty model ids are refused by catalog-translating providers" do
      assert Provider.native_model(ClaudeManagedAgents, "anthropic:") ==
               {:error, {:unsupported_model, "anthropic:"}}

      assert Provider.native_model(BedrockAgentCore, "bedrock:") ==
               {:error, {:unsupported_model, "bedrock:"}}
    end

    test "Local and providers without the callback send the catalog id as given" do
      assert Provider.native_model(Local, "ollama:qwen3") == {:ok, "ollama:qwen3"}

      assert Provider.native_model(FakeProviders.RequestResponse, "any:model") ==
               {:ok, "any:model"}
    end
  end
end

defmodule ReqManagedAgents.ProviderCapabilitiesLoadingTest do
  use ExUnit.Case, async: false

  alias ReqManagedAgents.Provider
  alias ReqManagedAgents.Providers.{ClaudeManagedAgents, Local}

  test "capabilities load a provider before reading its optional callbacks" do
    for {provider, capability} <- [
          {ClaudeManagedAgents, :outcomes},
          {ClaudeManagedAgents, :budget},
          {Local, :runtime_model}
        ] do
      unload(provider)
      assert Provider.supports?(provider, capability)
    end
  end

  test "the data-plane wire is available before the provider is loaded" do
    unload(Local)
    assert Provider.data_plane(Local) == :chat_completions
  end

  test "catalog translation is available before the provider is loaded" do
    unload(ClaudeManagedAgents)

    assert Provider.native_model(ClaudeManagedAgents, "anthropic:claude-haiku-4-5") ==
             {:ok, "claude-haiku-4-5"}
  end

  defp unload(provider) do
    assert Code.ensure_loaded?(provider)
    :code.delete(provider)
    :code.purge(provider)
    refute :erlang.module_loaded(provider)
  end
end
