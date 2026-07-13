defmodule ReqManagedAgents.Environment.SpecTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Environment.Spec
  alias ReqManagedAgents.Provisioner.Runtime

  describe "new/1" do
    test "nil is a valid (absent) environment" do
      assert {:ok, nil} = Spec.new(nil)
    end

    test "coerces a map, validating runtimes into %Runtime{} structs" do
      assert {:ok,
              %Spec{
                name: "prod",
                runtimes: [%Runtime{lang: :python, version: "3.12"}],
                config: %{a: 1}
              }} =
               Spec.new(%{
                 name: "prod",
                 runtimes: [%{lang: :python, version: "3.12"}],
                 config: %{a: 1}
               })
    end

    test "accepts an existing %Spec{} and re-validates its runtimes" do
      {:ok, spec} = Spec.new(%{runtimes: [%{lang: :node, version: "22"}]})
      assert {:ok, %Spec{runtimes: [%Runtime{lang: :node, version: "22"}]}} = Spec.new(spec)
    end

    test "accepts string-keyed maps" do
      assert {:ok, %Spec{name: "prod", config: %{"type" => "cloud"}}} =
               Spec.new(%{"name" => "prod", "runtimes" => [], "config" => %{"type" => "cloud"}})
    end

    test "an invalid runtime fails the whole coercion (no unvalidated runtime escapes)" do
      # missing :version — Runtime.new/1 rejects it
      assert {:error, :invalid_environment_spec} = Spec.new(%{runtimes: [%{lang: :python}]})
      # version with a shell-injection char — Runtime's charset gate rejects it
      assert {:error, :invalid_environment_spec} =
               Spec.new(%{runtimes: [%{lang: :python, version: "3.12; rm -rf /"}]})
    end

    test "a non-map, non-nil input is rejected" do
      assert {:error, :invalid_environment_spec} = Spec.new("nope")
    end

    test "defaults: empty runtimes and empty config" do
      assert {:ok, %Spec{name: nil, runtimes: [], config: %{}}} = Spec.new(%{})
    end
  end

  describe "digest/1" do
    test "is stable across calls" do
      {:ok, spec} = Spec.new(%{runtimes: [%{lang: :python, version: "3.12"}], config: %{a: 1}})
      assert Spec.digest(spec) == Spec.digest(spec)
    end

    test "excludes name (two specs differing only by name share a digest)" do
      {:ok, a} = Spec.new(%{name: "one", config: %{a: 1}})
      {:ok, b} = Spec.new(%{name: "two", config: %{a: 1}})
      assert Spec.digest(a) == Spec.digest(b)
    end

    test "differs when config differs" do
      {:ok, a} = Spec.new(%{config: %{a: 1}})
      {:ok, b} = Spec.new(%{config: %{a: 2}})
      refute Spec.digest(a) == Spec.digest(b)
    end

    test "differs when runtimes differ" do
      {:ok, a} = Spec.new(%{runtimes: [%{lang: :python, version: "3.12"}]})
      {:ok, b} = Spec.new(%{runtimes: [%{lang: :python, version: "3.13"}]})
      refute Spec.digest(a) == Spec.digest(b)
    end
  end
end
