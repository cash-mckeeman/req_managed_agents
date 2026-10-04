defmodule ReqManagedAgents.Provisioner.RuntimeTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Provisioner.Runtime

  describe "new/1" do
    test "accepts a valid map and defaults via to :mise" do
      assert {:ok, %Runtime{lang: :elixir, version: "1.17.0", via: :mise}} =
               Runtime.new(%{lang: :elixir, version: "1.17.0"})
    end

    test "accepts a valid map with an explicit via: :mise" do
      assert {:ok, %Runtime{lang: :erlang, version: "26.2.5", via: :mise}} =
               Runtime.new(%{lang: :erlang, version: "26.2.5", via: :mise})
    end

    test "rejects a version containing a shell-injection metacharacter" do
      entry = %{lang: :elixir, version: "1.0; rm -rf /", via: :mise}
      assert {:error, {:invalid_runtime, ^entry}} = Runtime.new(entry)
    end

    test "rejects a version containing shell metacharacters via newline" do
      entry = %{lang: :elixir, version: "1.18\nrm -rf /", via: :mise}
      assert {:error, {:invalid_runtime, ^entry}} = Runtime.new(entry)
    end

    test "rejects an empty version" do
      entry = %{lang: :elixir, version: "", via: :mise}
      assert {:error, {:invalid_runtime, ^entry}} = Runtime.new(entry)
    end

    test "accepts a version containing a hyphen (pre-suffixed OTP build)" do
      assert {:ok, %Runtime{version: "1.20.2-otp-29"}} =
               Runtime.new(%{lang: :elixir, version: "1.20.2-otp-29"})
    end

    test "rejects via other than :mise" do
      entry = %{lang: :elixir, version: "1.17.0", via: :nix}
      assert {:error, {:invalid_runtime, ^entry}} = Runtime.new(entry)
    end

    test "rejects non-map input" do
      assert {:error, {:invalid_runtime, :not_a_map}} = Runtime.new(:not_a_map)
      assert {:error, {:invalid_runtime, nil}} = Runtime.new(nil)
    end

    test "rejects a map missing :lang" do
      entry = %{version: "1.17.0", via: :mise}
      assert {:error, {:invalid_runtime, ^entry}} = Runtime.new(entry)
    end

    test "rejects a map missing :version" do
      entry = %{lang: :elixir, via: :mise}
      assert {:error, {:invalid_runtime, ^entry}} = Runtime.new(entry)
    end

    test "re-validates an existing struct and passes through when valid" do
      {:ok, runtime} = Runtime.new(%{lang: :elixir, version: "1.17.0"})
      assert {:ok, ^runtime} = Runtime.new(runtime)
    end

    test "re-validates an existing struct and rejects a struct with an injected version" do
      bad = %Runtime{lang: :elixir, version: "1.0; rm -rf /", via: :mise}
      assert {:error, {:invalid_runtime, ^bad}} = Runtime.new(bad)
    end
  end
end
