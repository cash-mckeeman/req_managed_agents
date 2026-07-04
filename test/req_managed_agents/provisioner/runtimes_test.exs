defmodule ReqManagedAgents.Provisioner.RuntimesTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Provisioner
  alias ReqManagedAgents.Provisioner.Runtimes
  alias ReqManagedAgents.Provisioner.Store

  # ---------------------------------------------------------------------------
  # validate/1
  # ---------------------------------------------------------------------------

  describe "validate/1" do
    test "accepts valid elixir entry" do
      assert :ok = Runtimes.validate([%{lang: :elixir, version: "1.17.0", via: :mise}])
    end

    test "accepts valid erlang entry" do
      assert :ok = Runtimes.validate([%{lang: :erlang, version: "26.2.5", via: :mise}])
    end

    test "accepts empty list" do
      assert :ok = Runtimes.validate([])
    end

    test "rejects unknown via" do
      entry = %{lang: :elixir, version: "1.17.0", via: :nix}
      assert {:error, {:invalid_runtime, ^entry}} = Runtimes.validate([entry])
    end

    test "rejects missing version" do
      entry = %{lang: :elixir, via: :mise}
      assert {:error, {:invalid_runtime, ^entry}} = Runtimes.validate([entry])
    end

    test "rejects missing lang" do
      entry = %{version: "1.17.0", via: :mise}
      assert {:error, {:invalid_runtime, ^entry}} = Runtimes.validate([entry])
    end

    test "rejects non-list input" do
      assert {:error, {:invalid_runtime, :not_a_list}} = Runtimes.validate(:not_a_list)
    end

    test "rejects nil" do
      assert {:error, {:invalid_runtime, nil}} = Runtimes.validate(nil)
    end

    test "first invalid entry in a mixed list is reported" do
      good = %{lang: :erlang, version: "26.2.5", via: :mise}
      bad = %{lang: :elixir, version: "1.17.0", via: :nix}
      assert {:error, {:invalid_runtime, ^bad}} = Runtimes.validate([good, bad])
    end

    test "rejects version with shell metacharacters" do
      entry = %{lang: :elixir, version: "1.18\nrm -rf /", via: :mise}
      assert {:error, {:invalid_runtime, ^entry}} = Runtimes.validate([entry])
    end

    test "rejects empty version" do
      entry = %{lang: :elixir, version: "", via: :mise}
      assert {:error, {:invalid_runtime, ^entry}} = Runtimes.validate([entry])
    end

    test "accepts version containing a hyphen (pre-suffixed OTP build)" do
      assert :ok = Runtimes.validate([%{lang: :elixir, version: "1.20.2-otp-29", via: :mise}])
    end
  end

  # ---------------------------------------------------------------------------
  # bootstrap_script/1
  # ---------------------------------------------------------------------------

  describe "bootstrap_script/1" do
    test "renders shebang, pipefail, and locale exports" do
      script = Runtimes.bootstrap_script([%{lang: :elixir, version: "1.17.0", via: :mise}])
      assert String.starts_with?(script, "#!/usr/bin/env bash\n")
      assert script =~ "set -euo pipefail"
      assert script =~ "export LC_ALL=C.UTF-8 LANG=C.UTF-8"
    end

    test "renders mise use --global and mise install" do
      script = Runtimes.bootstrap_script([%{lang: :elixir, version: "1.17.0", via: :mise}])
      assert script =~ "mise use --global elixir@1.17.0"
      assert script =~ "mise install"
    end

    test "erlang appears before elixir when both present" do
      runtimes = [
        %{lang: :elixir, version: "1.17.0", via: :mise},
        %{lang: :erlang, version: "26.2.5", via: :mise}
      ]

      script = Runtimes.bootstrap_script(runtimes)
      {erlang_pos, _} = :binary.match(script, "mise use --global erlang@")
      {elixir_pos, _} = :binary.match(script, "mise use --global elixir@")
      assert erlang_pos < elixir_pos
    end

    test "elixir version gets OTP suffix when erlang is present" do
      runtimes = [
        %{lang: :elixir, version: "1.17.0", via: :mise},
        %{lang: :erlang, version: "26.2.5", via: :mise}
      ]

      script = Runtimes.bootstrap_script(runtimes)
      assert script =~ "mise use --global elixir@1.17.0-otp-26"
    end

    test "elixir version is plain when no erlang present" do
      runtimes = [%{lang: :elixir, version: "1.17.0", via: :mise}]
      script = Runtimes.bootstrap_script(runtimes)
      assert script =~ "mise use --global elixir@1.17.0"
      refute script =~ "-otp-"
    end

    test "erlang major is derived from the version up to first dot" do
      runtimes = [
        %{lang: :erlang, version: "27.1.2", via: :mise},
        %{lang: :elixir, version: "1.18.0", via: :mise}
      ]

      script = Runtimes.bootstrap_script(runtimes)
      assert script =~ "mise use --global elixir@1.18.0-otp-27"
    end

    test "other languages render as lang@version verbatim" do
      runtimes = [%{lang: :nodejs, version: "20.0.0", via: :mise}]
      script = Runtimes.bootstrap_script(runtimes)
      assert script =~ "mise use --global nodejs@20.0.0"
    end

    test "other langs preserve input order after the erlang/elixir pair" do
      runtimes = [
        %{lang: :erlang, version: "26.2.5", via: :mise},
        %{lang: :python, version: "3.12.0", via: :mise},
        %{lang: :elixir, version: "1.17.0", via: :mise},
        %{lang: :nodejs, version: "20.0.0", via: :mise}
      ]

      script = Runtimes.bootstrap_script(runtimes)
      {erlang_pos, _} = :binary.match(script, "erlang@")
      {elixir_pos, _} = :binary.match(script, "elixir@")
      {python_pos, _} = :binary.match(script, "python@")
      {node_pos, _} = :binary.match(script, "nodejs@")

      assert erlang_pos < elixir_pos
      assert elixir_pos < python_pos
      assert python_pos < node_pos
    end

    test "is deterministic: same input produces identical binary" do
      runtimes = [
        %{lang: :erlang, version: "26.2.5", via: :mise},
        %{lang: :elixir, version: "1.17.0", via: :mise},
        %{lang: :nodejs, version: "20.0.0", via: :mise}
      ]

      assert Runtimes.bootstrap_script(runtimes) == Runtimes.bootstrap_script(runtimes)
    end

    test "installs mise when absent, then exports PATH, before any mise use" do
      script = Runtimes.bootstrap_script([%{lang: :elixir, version: "1.17.0", via: :mise}])

      installer =
        "command -v mise >/dev/null 2>&1 || curl -fsSL https://mise.jdx.dev/install.sh | sh"

      path_export = ~S(export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH")

      {installer_pos, _} = :binary.match(script, installer)
      {path_pos, _} = :binary.match(script, path_export)
      {use_pos, _} = :binary.match(script, "mise use --global")

      assert installer_pos < path_pos
      assert path_pos < use_pos
    end

    test "persists PATH + locale to ~/.bashrc, guarded by the marker comment" do
      script = Runtimes.bootstrap_script([%{lang: :elixir, version: "1.17.0", via: :mise}])

      assert script =~ "grep -q 'mise activate-rma' ~/.bashrc"
      assert script =~ "# mise activate-rma"
      assert script =~ "export LC_ALL=C.UTF-8 LANG=C.UTF-8"

      # The persistence block comes AFTER the final `mise install`.
      {install_pos, _} = :binary.match(script, "mise install\n")
      {guard_pos, _} = :binary.match(script, "grep -q 'mise activate-rma'")
      assert install_pos < guard_pos

      # The bashrc block re-exports PATH (second occurrence of the export line).
      path_export = ~S(export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH")
      assert length(String.split(script, path_export)) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # system_prompt_block/1
  # ---------------------------------------------------------------------------

  describe "system_prompt_block/1" do
    @block_runtimes [
      %{lang: :erlang, version: "29.0.2", via: :mise},
      %{lang: :elixir, version: "1.20.2", via: :mise}
    ]

    test "names each declared runtime as \"<lang> <version>\"" do
      block = Runtimes.system_prompt_block(@block_runtimes)
      assert block =~ "erlang 29.0.2"
      assert block =~ "elixir 1.20.2"
    end

    test "instructs exactly-once execution via bash and notes idempotence" do
      block = Runtimes.system_prompt_block(@block_runtimes)
      assert block =~ "EXACTLY ONCE"
      assert block =~ "bash"
      assert block =~ "idempotent"
    end

    test "embeds the full bootstrap script verbatim in a fenced block" do
      block = Runtimes.system_prompt_block(@block_runtimes)
      script = Runtimes.bootstrap_script(@block_runtimes)
      assert block =~ "```bash"
      assert String.contains?(block, script)
    end

    test "is deterministic: renders identically twice" do
      assert Runtimes.system_prompt_block(@block_runtimes) ==
               Runtimes.system_prompt_block(@block_runtimes)
    end
  end

  # ---------------------------------------------------------------------------
  # required_hosts/1
  # ---------------------------------------------------------------------------

  describe "required_hosts/1" do
    test "returns a non-empty sorted, deduped list for :mise runtimes" do
      runtimes = [%{lang: :elixir, version: "1.17.0", via: :mise}]
      hosts = Runtimes.required_hosts(runtimes)
      assert is_list(hosts)
      assert hosts != []
      assert hosts == Enum.sort(hosts)
      assert hosts == Enum.uniq(hosts)
    end

    test "includes known mise hosts" do
      runtimes = [%{lang: :erlang, version: "26.2.5", via: :mise}]
      hosts = Runtimes.required_hosts(runtimes)
      assert "mise.jdx.dev" in hosts
      assert "github.com" in hosts
      assert "objects.githubusercontent.com" in hosts
      assert "repo.hex.pm" in hosts
      assert "builds.hex.pm" in hosts
    end

    test "returns empty list for empty runtimes" do
      assert [] = Runtimes.required_hosts([])
    end
  end

  # ---------------------------------------------------------------------------
  # ensure_environment integration
  # ---------------------------------------------------------------------------

  @runtimes [%{lang: :elixir, version: "1.17.0", via: :mise}]

  defmodule SpyStore do
    @moduledoc false
    # Records every call as a message to the test pid (passed as store opts).
    # A raising store can't prove call ordering here: Environments.store_get
    # rescues store exceptions and treats them as a miss.
    @behaviour Store

    @impl true
    def get(pid, key) do
      send(pid, {:store_get, key})
      :miss
    end

    @impl true
    def put(pid, key, _value) do
      send(pid, {:store_put, key})
      :ok
    end

    @impl true
    def delete(_pid, _key), do: :ok

    @impl true
    def delete_value(_pid, _value), do: :ok
  end

  defp fresh_store do
    {Store.ETS, :"runtime_env_store_#{System.unique_integer([:positive])}"}
  end

  defp capture_create(test_pid) do
    fn body ->
      send(test_pid, {:create, body})
      {:ok, %{"id" => "env_123", "name" => body.name}}
    end
  end

  describe "ensure_environment with runtimes" do
    test "spec with runtimes yields different digest-name than spec without" do
      store = fresh_store()
      create_fun = fn body -> {:ok, %{"id" => body.name, "name" => body.name}} end

      spec_without = %{type: :cloud, networking: %{type: :unrestricted}}
      spec_with = Map.put(spec_without, :runtimes, @runtimes)

      {:ok, %{name: name_without}} =
        Provisioner.ensure_environment(:c, spec_without,
          name: "env",
          store: store,
          create_fun: create_fun
        )

      {:ok, %{name: name_with}} =
        Provisioner.ensure_environment(:c, spec_with,
          name: "env",
          store: store,
          create_fun: create_fun
        )

      refute name_without == name_with
    end

    test "validation error returns before any store/create call" do
      invalid = [%{lang: :elixir, version: "1.17.0", via: :nix}]
      spec = %{type: :cloud, runtimes: invalid}

      assert {:error, {:invalid_runtime, _}} =
               Provisioner.ensure_environment(:c, spec,
                 name: "env",
                 store: {SpyStore, self()},
                 create_fun: fn _ -> flunk("create must not be called on validation error") end
               )

      refute_received {:store_get, _}
      refute_received {:store_put, _}
    end

    test "unrestricted networking: create body unchanged (no allowed_hosts injected)" do
      spec = %{type: :cloud, runtimes: @runtimes, networking: %{type: :unrestricted}}

      {:ok, _} =
        Provisioner.ensure_environment(:c, spec,
          name: "env",
          store: fresh_store(),
          create_fun: capture_create(self())
        )

      assert_received {:create, body}
      refute get_in(body, [:config, :networking, :allowed_hosts])
    end

    test "limited networking: runtimes' required hosts merged into allowed_hosts" do
      spec = %{
        type: :cloud,
        runtimes: @runtimes,
        networking: %{type: :limited, allowed_hosts: ["example.com"]}
      }

      {:ok, _} =
        Provisioner.ensure_environment(:c, spec,
          name: "env",
          store: fresh_store(),
          create_fun: capture_create(self())
        )

      assert_received {:create, body}
      hosts = get_in(body, [:config, :networking, :allowed_hosts])
      assert is_list(hosts)
      assert "example.com" in hosts
      assert "mise.jdx.dev" in hosts
    end

    test "limited networking: hosts deduplicated when consumer already lists a runtime host" do
      runtime_hosts = Runtimes.required_hosts(@runtimes)
      [one_host | _] = runtime_hosts

      spec = %{
        type: :cloud,
        runtimes: @runtimes,
        networking: %{type: :limited, allowed_hosts: [one_host, "example.com"]}
      }

      {:ok, _} =
        Provisioner.ensure_environment(:c, spec,
          name: "env",
          store: fresh_store(),
          create_fun: capture_create(self())
        )

      assert_received {:create, body}
      hosts = get_in(body, [:config, :networking, :allowed_hosts])
      assert Enum.count(hosts, &(&1 == one_host)) == 1
    end

    test "limited networking as string type: hosts merged" do
      spec = %{
        type: :cloud,
        runtimes: @runtimes,
        networking: %{type: "limited", allowed_hosts: []}
      }

      {:ok, _} =
        Provisioner.ensure_environment(:c, spec,
          name: "env",
          store: fresh_store(),
          create_fun: capture_create(self())
        )

      assert_received {:create, body}
      hosts = get_in(body, [:config, :networking, :allowed_hosts])
      assert "mise.jdx.dev" in hosts
    end

    test "absent networking key: create body unchanged (no networking key added)" do
      spec = %{type: :cloud, runtimes: @runtimes}

      {:ok, _} =
        Provisioner.ensure_environment(:c, spec,
          name: "env",
          store: fresh_store(),
          create_fun: capture_create(self())
        )

      assert_received {:create, body}
      refute get_in(body, [:config, :networking])
    end

    test "string-keyed limited networking map: hosts merged under the string key" do
      spec = %{
        type: :cloud,
        runtimes: @runtimes,
        networking: %{"type" => "limited", "allowed_hosts" => ["example.com"]}
      }

      {:ok, _} =
        Provisioner.ensure_environment(:c, spec,
          name: "env",
          store: fresh_store(),
          create_fun: capture_create(self())
        )

      assert_received {:create, body}
      hosts = body.config[:networking]["allowed_hosts"]
      assert is_list(hosts)
      assert "example.com" in hosts
      assert "mise.jdx.dev" in hosts
      # No atom-keyed duplicate written into the string-keyed map.
      refute Map.has_key?(body.config[:networking], :allowed_hosts)
    end

    test "string-keyed unrestricted networking map: create body unchanged" do
      networking = %{"type" => "unrestricted"}
      spec = %{type: :cloud, runtimes: @runtimes, networking: networking}

      {:ok, _} =
        Provisioner.ensure_environment(:c, spec,
          name: "env",
          store: fresh_store(),
          create_fun: capture_create(self())
        )

      assert_received {:create, body}
      assert body.config[:networking] == networking
    end
  end
end
