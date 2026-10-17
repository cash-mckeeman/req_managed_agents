defmodule ReqManagedAgents.ModelConfigTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.ModelConfig

  test "an atom-keyed map with the canonical keys becomes a struct" do
    assert {:ok,
            %ModelConfig{
              model: "m",
              api_key: "k",
              bearer_token_file: nil,
              base_url: "http://x",
              metadata: %{request_id: "r"}
            }} =
             ModelConfig.new(%{
               model: "m",
               api_key: "k",
               base_url: "http://x",
               metadata: %{request_id: "r"}
             })
  end

  test "a keyword list and an existing struct are accepted and validated" do
    assert {:ok, %ModelConfig{model: "m"}} = ModelConfig.new(model: "m")
    {:ok, config} = ModelConfig.new(%{api_key: "k"})
    assert ModelConfig.new(config) == {:ok, config}
    assert {:ok, %ModelConfig{metadata: %{}}} = ModelConfig.new([])
    assert ModelConfig.new(%ModelConfig{api_key: 1}) == {:error, {:invalid, :api_key}}
  end

  test "string keys are unknown keys, so a string-keyed routed map is refused" do
    assert ModelConfig.new(%{"key" => "k", "model" => "m"}) ==
             {:error, {:unknown_keys, ["key", "model"]}}
  end

  test "an unknown atom key is refused, not ignored" do
    assert ModelConfig.new(%{model: "m", provider_options: []}) ==
             {:error, {:unknown_keys, [:provider_options]}}
  end

  test "credential and destination keys are binaries or nil" do
    for key <- [:api_key, :bearer_token_file, :base_url] do
      assert ModelConfig.new(%{key => 1}) == {:error, {:invalid, key}}
      assert {:ok, _} = ModelConfig.new(%{key => nil})
    end
  end

  test "metadata is a map, and nil means none" do
    for metadata <- [[request_id: "r"], false, 1, "metadata"] do
      assert ModelConfig.new(%{metadata: metadata}) == {:error, {:invalid, :metadata}}
    end

    assert {:ok, %ModelConfig{metadata: %{}}} = ModelConfig.new(%{metadata: nil})
  end

  test "anything else is not a model config" do
    assert ModelConfig.new("m") == {:error, :not_a_map}
    assert ModelConfig.new([1, 2]) == {:error, :not_a_map}
    assert ModelConfig.new(nil) == {:error, :not_a_map}
  end

  test "provider-native model values pass through without coercion" do
    for model <- [false, 0, [], %{"bedrockModelConfig" => %{"modelId" => "m"}}] do
      assert {:ok, %ModelConfig{model: ^model} = config} = ModelConfig.new(%{model: model})
      assert ModelConfig.to_map(config) == %{model: model}
    end
  end

  test "to_map/1 keeps only the keys that were set" do
    {:ok, config} = ModelConfig.new(%{model: "m", api_key: nil})
    assert ModelConfig.to_map(config) == %{model: "m"}
    assert ModelConfig.to_map(%ModelConfig{}) == %{}

    {:ok, config} = ModelConfig.new(%{metadata: %{a: 1}, base_url: "u"})
    assert ModelConfig.to_map(config) == %{metadata: %{a: 1}, base_url: "u"}
  end

  test "inspect/1 never shows the credential" do
    {:ok, config} = ModelConfig.new(%{api_key: "sk-secret-123", model: "m"})
    refute inspect(config) =~ "sk-secret-123"
    assert inspect(config) =~ "\"m\""
  end

  test "data_plane?/1 is true when any credential or destination key is set" do
    for key <- [:api_key, :bearer_token_file, :base_url] do
      {:ok, config} = ModelConfig.new(%{key => "v"})
      assert ModelConfig.data_plane?(config)
    end

    {:ok, config} = ModelConfig.new(%{model: "m", metadata: %{a: 1}})
    refute ModelConfig.data_plane?(config)

    {:ok, config} = ModelConfig.new(%{api_key: ""})
    assert ModelConfig.data_plane?(config)
  end

  test "data_plane?/1 accepts canonical provider projections with nil fields" do
    for {attrs, expected} <- [
          {%{}, false},
          {%{api_key: nil, bearer_token_file: nil, base_url: nil}, false},
          {%{model: "model", metadata: %{request_id: "r"}}, false},
          {%{api_key: "key"}, true},
          {%{bearer_token_file: "/token"}, true},
          {%{base_url: "http://localhost"}, true},
          {%{api_key: ""}, true}
        ] do
      {:ok, config} = ModelConfig.new(attrs)
      assert ModelConfig.data_plane?(config) == expected
      assert ModelConfig.data_plane?(ModelConfig.to_map(config)) == expected
      assert ModelConfig.data_plane?(attrs) == expected
    end
  end
end
