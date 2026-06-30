# RMA Agent Provisioning & Teardown — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make provider-side agent provisioning/teardown a first-class part of the
`ReqManagedAgents.Provider` abstraction — the symmetric *setup* half of invocation.

**Architecture:** Add `provision/2` (required) + `teardown/2` (optional) callbacks to the `Provider`
behaviour; generalize `Provisioner` into an opaque, `{provider, spec}`-keyed cache that calls
`provider.provision/2`; expose `ReqManagedAgents.provision/3` + `teardown/3`; implement the two
providers, relocating the AgentCore create/READY-poll/reuse logic in from biai-managed-agents.

**Tech Stack:** Elixir, ExUnit, Bypass (AgentCore SigV4 client), Req.Test (Claude client), jj.

## Global Constraints

- Each commit message ends with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- `provision/2` is a **required** `Provider` callback; `teardown/2` is **optional** (`@optional_callbacks teardown: 2`).
- `model_config` is an **opaque pass-through** — providers hand it to the control plane verbatim (Bedrock: as the harness `model` field; Claude: as the agent `model` field). RMA never interprets it.
- The provisioned **handle** is what `open/2` already consumes — Claude `%{agent_id, environment_id}`, Bedrock `%{harness_arn, harness_id}` (`open/2` reads `harness_arn`; `harness_id` is carried for `get_harness`/`delete_harness`). **`Session.run/2` is unchanged.**
- `Provisioner` cache key is `hash({provider, spec})`; the ETS cache is an in-process optimization, the handle is the durable artifact.
- Tests use injected seams (`:create_fun` / `:delete_fun`) or Bypass/Req.Test — **no live AWS/Anthropic**.
- Canonical spec: `%{system_prompt: String.t(), tools: [map()], terminal_tool: String.t() | nil, model_config: term()}`.

**Note (refines the spec):** `teardown` takes `(handle, opts)` not `(handle)` — teardown needs a client (in `opts[:client]`, or the `:delete_fun` seam), exactly as `provision` does. The spec's `teardown/1` is superseded by `teardown/2`.

---

### Task 1: Provider callbacks + generalized Provisioner + facade

**Files:**
- Modify: `lib/req_managed_agents/provider.ex` (add `spec`/`handle` types + `provision/2`/`teardown/2` callbacks; extend `@optional_callbacks`)
- Modify: `lib/req_managed_agents/provisioner.ex` (generalize to `ensure/3` + `evict/1`)
- Modify: `lib/req_managed_agents.ex` (add `provision/3` + `teardown/3`)
- Test: `test/req_managed_agents/provisioning_test.exs` (new)

**Interfaces:**
- Produces: `ReqManagedAgents.Provider.spec()`, `ReqManagedAgents.Provider.handle()`; `@callback provision(spec(), keyword()) :: {:ok, handle()} | {:error, term()}`; `@callback teardown(handle(), keyword()) :: :ok | {:error, term()}`; `ReqManagedAgents.Provisioner.ensure(provider, spec, opts) :: {:ok, handle} | {:error, {:provision_failed, reason}}`; `ReqManagedAgents.Provisioner.evict(handle) :: :ok`; `ReqManagedAgents.provision(provider, spec, opts \\ [])`; `ReqManagedAgents.teardown(provider, handle, opts \\ [])`.

- [ ] **Step 1: Write the failing test** — `test/req_managed_agents/provisioning_test.exs`

```elixir
defmodule ReqManagedAgents.ProvisioningTest do
  use ExUnit.Case, async: false
  alias ReqManagedAgents.Provisioner

  defmodule FakeProvider do
    def provision(spec, opts), do: opts[:create_fun].(spec)
    def teardown(handle, opts) do
      case (opts[:delete_fun] || fn _ -> {:ok, %{}} end).(handle) do
        {:ok, _} -> :ok
        err -> err
      end
    end
  end

  defmodule NoTeardownProvider do
    def provision(spec, opts), do: opts[:create_fun].(spec)
  end

  @spec_a %{system_prompt: "s", tools: [], terminal_tool: nil, model_config: "m"}

  setup do
    Provisioner.reset()
    :ok
  end

  test "ensure/3 provisions on miss and serves cache on hit (provision called once)" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    create = fn _ -> Agent.update(counter, &(&1 + 1)); {:ok, %{id: "h1"}} end

    assert {:ok, %{id: "h1"}} = Provisioner.ensure(FakeProvider, @spec_a, create_fun: create)
    assert {:ok, %{id: "h1"}} = Provisioner.ensure(FakeProvider, @spec_a, create_fun: create)
    assert Agent.get(counter, & &1) == 1
  end

  test "ensure/3 is keyed by {provider, spec}: same spec on two providers → two handles" do
    assert {:ok, %{id: "a"}} = Provisioner.ensure(FakeProvider, @spec_a, create_fun: fn _ -> {:ok, %{id: "a"}} end)
    assert {:ok, %{id: "b"}} = Provisioner.ensure(NoTeardownProvider, @spec_a, create_fun: fn _ -> {:ok, %{id: "b"}} end)
  end

  test "ensure/3 wraps a provision error and does not cache it" do
    assert {:error, {:provision_failed, :boom}} =
             Provisioner.ensure(FakeProvider, @spec_a, create_fun: fn _ -> {:error, :boom} end)

    assert {:ok, %{id: "ok"}} =
             Provisioner.ensure(FakeProvider, @spec_a, create_fun: fn _ -> {:ok, %{id: "ok"}} end)
  end

  test "ReqManagedAgents.provision/3 delegates to the cache" do
    assert {:ok, %{id: "h"}} =
             ReqManagedAgents.provision(FakeProvider, @spec_a, create_fun: fn _ -> {:ok, %{id: "h"}} end)
  end

  test "teardown/3 tears down + evicts; provider without teardown → {:error, :not_supported}" do
    {:ok, torn} = Agent.start_link(fn -> [] end)
    {:ok, %{id: "h"}} = Provisioner.ensure(FakeProvider, @spec_a, create_fun: fn _ -> {:ok, %{id: "h"}} end)

    delete = fn h -> Agent.update(torn, &[h.id | &1]); {:ok, %{}} end
    assert :ok = ReqManagedAgents.teardown(FakeProvider, %{id: "h"}, delete_fun: delete)
    assert Agent.get(torn, & &1) == ["h"]

    # evicted: a subsequent ensure re-provisions
    {:ok, c} = Agent.start_link(fn -> 0 end)
    assert {:ok, %{id: "h2"}} =
             Provisioner.ensure(FakeProvider, @spec_a, create_fun: fn _ -> Agent.update(c, &(&1 + 1)); {:ok, %{id: "h2"}} end)
    assert Agent.get(c, & &1) == 1

    assert {:error, :not_supported} = ReqManagedAgents.teardown(NoTeardownProvider, %{id: "x"})
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/req_managed_agents/provisioning_test.exs`
Expected: FAIL — `Provisioner.ensure/3` undefined and `ReqManagedAgents.provision/3` undefined.

- [ ] **Step 3: Add the behaviour types + callbacks** — `lib/req_managed_agents/provider.ex`

Add after the `turn_outcome` type (near the `conn`/`input` typedocs):

```elixir
  @typedoc "A provider-agnostic agent definition — the input to provisioning and the cache key."
  @type spec :: %{
          system_prompt: String.t(),
          tools: [map()],
          terminal_tool: String.t() | nil,
          model_config: term()
        }

  @typedoc "Provider-private handle to a provisioned, reusable server-side resource."
  @type handle :: term()
```

Add after the `normalize` callback:

```elixir
  @doc "Create (or look up) the provider-side agent resource for `spec`; return a durable handle."
  @callback provision(spec(), opts :: keyword()) :: {:ok, handle()} | {:error, term()}

  @doc "Delete the provider-side resource named by `handle`. `opts` carries the client / test seam."
  @callback teardown(handle(), opts :: keyword()) :: :ok | {:error, term()}
```

Change the existing `@optional_callbacks` line to add `teardown: 2`:

```elixir
  @optional_callbacks poll_turn: 2, push_input: 2, turn_boundary?: 1, reconnect: 3, teardown: 2
```

- [ ] **Step 4: Generalize the Provisioner** — replace `lib/req_managed_agents/provisioner.ex` body

```elixir
defmodule ReqManagedAgents.Provisioner do
  @moduledoc """
  Hash-keyed provision cache. `ensure/3` returns a cached provider `handle` for a given
  `{provider, spec}`, calling `provider.provision/2` only on a miss. ETS-backed
  (process-independent); the handle is the durable artifact (persistable + reusable across
  processes), so the cache is an in-process optimization, not the source of truth.
  """
  alias ReqManagedAgents.Provider
  @table :req_managed_agents_provisions

  @spec ensure(module(), Provider.spec(), keyword()) ::
          {:ok, Provider.handle()} | {:error, term()}
  def ensure(provider, spec, opts \\ []) do
    table = ensure_table()
    key = hash({provider, spec})

    case :ets.lookup(table, key) do
      [{^key, handle}] ->
        {:ok, handle}

      [] ->
        case provider.provision(spec, opts) do
          {:ok, handle} ->
            :ets.insert(table, {key, handle})
            {:ok, handle}

          {:error, reason} ->
            {:error, {:provision_failed, reason}}
        end
    end
  end

  @doc "Drop any cache entry whose value is `handle` (called after teardown)."
  @spec evict(Provider.handle()) :: :ok
  def evict(handle) do
    if :ets.whereis(@table) != :undefined, do: :ets.match_delete(@table, {:"$1", handle})
    :ok
  end

  @doc false
  def reset,
    do: if(:ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table), else: :ok)

  defp hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16()

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _ref -> @table
    end
  end
end
```

- [ ] **Step 5: Add the facade** — `lib/req_managed_agents.ex` (add before the final `end`)

```elixir
  @doc """
  Provision (create-or-reuse) a provider's agent resource for `spec`, returning a durable
  `handle` you splat into `ReqManagedAgents.Session.run/2` opts. Cached in-process by
  `{provider, spec}`.
  """
  @spec provision(module(), ReqManagedAgents.Provider.spec(), keyword()) ::
          {:ok, ReqManagedAgents.Provider.handle()} | {:error, term()}
  def provision(provider, spec, opts \\ []),
    do: ReqManagedAgents.Provisioner.ensure(provider, spec, opts)

  @doc "Tear down a provisioned resource and evict it from the provision cache."
  @spec teardown(module(), ReqManagedAgents.Provider.handle(), keyword()) :: :ok | {:error, term()}
  def teardown(provider, handle, opts \\ []) do
    if function_exported?(provider, :teardown, 2) do
      result = provider.teardown(handle, opts)
      ReqManagedAgents.Provisioner.evict(handle)
      result
    else
      {:error, :not_supported}
    end
  end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/req_managed_agents/provisioning_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 7: Full suite + warnings-as-errors**

Run: `mix compile --warnings-as-errors && mix test`
Expected: PASS, no warnings. (The old `Provisioner.ensure/2` arity is gone; confirm no in-repo caller broke — there are none; biai migrates separately.)

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(provider): provision/2 + teardown/2 callbacks + generalized Provisioner + facade

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
jj new
```

---

### Task 2: BedrockAgentCore provision/teardown

**Files:**
- Modify: `lib/req_managed_agents/providers/bedrock_agent_core.ex`
- Test: `test/req_managed_agents/providers/bedrock_agent_core_test.exs`

**Interfaces:**
- Consumes: the `provision/2`/`teardown/2` callbacks from Task 1; `ReqManagedAgents.AgentCore.Client.{create_harness/2, get_harness/2, list_harnesses/1, delete_harness/2}` (all exist) which return: `create_harness → {:ok, %{"harnessArn" => arn, "harnessId" => hid, ...}}`, `get_harness → {:ok, %{"harness" => %{"status" => s, ...}}}`, `list_harnesses → {:ok, %{"harnesses" => [%{"harnessName", "harnessId", "arn", "status"}], ...}}`, `delete_harness → {:ok, _}`.
- Produces: `BedrockAgentCore.provision(spec, opts) :: {:ok, %{harness_arn, harness_id}} | {:error, term()}`; `teardown(%{harness_id}, opts) :: :ok | {:error, term()}`.

- [ ] **Step 1: Write the failing test** — add to `test/req_managed_agents/providers/bedrock_agent_core_test.exs`

```elixir
  alias ReqManagedAgents.Providers.BedrockAgentCore, as: P

  @spec_bedrock %{system_prompt: "be helpful", tools: [%{"name" => "t"}], terminal_tool: nil,
                  model_config: %{"bedrockModelConfig" => %{"modelId" => "anthropic.claude-sonnet-4"}}}

  defp prov_opts(create_fun, extra \\ []) do
    [execution_role_arn: "arn:aws:iam::1:role/R", create_fun: create_fun,
     get_fun: fn _hid -> {:ok, %{"harness" => %{"status" => "READY"}}} end] ++ extra
  end

  test "provision/2 creates a harness, polls READY, returns {harness_arn, harness_id}" do
    create = fn harness_spec ->
      assert harness_spec.system_prompt == "be helpful"
      assert harness_spec.model == @spec_bedrock.model_config
      assert harness_spec.execution_role_arn == "arn:aws:iam::1:role/R"
      assert is_binary(harness_spec.name)
      {:ok, %{"harnessArn" => "arn:harness/x", "harnessId" => "h1"}}
    end

    assert {:ok, %{harness_arn: "arn:harness/x", harness_id: "h1"}} =
             P.provision(@spec_bedrock, prov_opts(create))
  end

  test "provision/2 recovers an existing harness when CreateHarness 409s" do
    name = P.harness_name(@spec_bedrock, nil)
    create = fn _ -> {:error, {:http_error, 409, %{}}} end

    list = fn ->
      {:ok, %{"harnesses" => [%{"harnessName" => name, "harnessId" => "h9", "arn" => "arn:harness/exist", "status" => "READY"}]}}
    end

    assert {:ok, %{harness_arn: "arn:harness/exist", harness_id: "h9"}} =
             P.provision(@spec_bedrock, prov_opts(create, list_fun: list))
  end

  test "teardown/2 deletes the harness by id" do
    {:ok, deleted} = Agent.start_link(fn -> nil end)
    delete = fn hid -> Agent.update(deleted, fn _ -> hid end); {:ok, %{}} end
    assert :ok = P.teardown(%{harness_arn: "a", harness_id: "h1"}, delete_fun: delete)
    assert Agent.get(deleted, & &1) == "h1"
  end
```

> The 409-recovery test computes the expected deterministic name via `P.harness_name/2` (exposed
> `@doc false` in Step 3) and feeds it to the `list` stub, so the name-match branch is exercised exactly.
> The `prov_opts/2` helper's `get_fun` returns `READY` immediately, so the READY-poll never sleeps.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/req_managed_agents/providers/bedrock_agent_core_test.exs`
Expected: FAIL — `BedrockAgentCore.provision/2` undefined.

- [ ] **Step 3: Implement provision/teardown** — add to `lib/req_managed_agents/providers/bedrock_agent_core.ex`

```elixir
  @ready_poll_ms 5_000
  @ready_max_polls 72
  @nonreusable_status ~w(DELETING DELETE_FAILED CREATE_FAILED UPDATE_FAILED)

  @impl true
  def provision(spec, opts) do
    client = opts[:client] || Client.new()
    name = harness_name(spec, opts[:name_prefix])

    harness_spec = %{
      name: name,
      execution_role_arn: Keyword.fetch!(opts, :execution_role_arn),
      system_prompt: spec.system_prompt,
      model: spec.model_config,
      tools: spec.tools
    }

    create_fun = opts[:create_fun] || fn s -> Client.create_harness(client, s) end
    list_fun = opts[:list_fun] || fn -> Client.list_harnesses(client) end
    get_fun = opts[:get_fun] || fn hid -> Client.get_harness(client, hid) end

    case create_fun.(harness_spec) do
      {:ok, %{"harnessArn" => arn, "harnessId" => hid}} ->
        with :ok <- wait_until_ready(get_fun, hid), do: {:ok, %{harness_arn: arn, harness_id: hid}}

      {:error, {:http_error, 409, _}} ->
        recover_existing(list_fun, get_fun, name)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def teardown(%{harness_id: hid}, opts) do
    client = opts[:client] || Client.new()
    delete_fun = opts[:delete_fun] || fn id -> Client.delete_harness(client, id) end

    case delete_fun.(hid) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def harness_name(spec, prefix) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(spec))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    [prefix, "harness_#{digest}"] |> Enum.reject(&is_nil/1) |> Enum.join("_")
  end

  defp recover_existing(list_fun, get_fun, name) do
    with {:ok, %{"harnesses" => harnesses}} <- list_fun.(),
         %{"arn" => arn, "harnessId" => hid} <- recoverable_harness(harnesses, name),
         :ok <- wait_until_ready(get_fun, hid) do
      {:ok, %{harness_arn: arn, harness_id: hid}}
    else
      nil -> {:error, {:harness_name_conflict, name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recoverable_harness(harnesses, name) do
    Enum.find(harnesses, fn h ->
      h["harnessName"] == name and h["status"] not in @nonreusable_status
    end)
  end

  defp wait_until_ready(get_fun, hid, polls_left \\ @ready_max_polls) do
    case get_fun.(hid) do
      {:ok, %{"harness" => %{"status" => "READY"}}} ->
        :ok

      {:ok, %{"harness" => %{"status" => s}}} when s in ["CREATE_FAILED", "UPDATE_FAILED", "DELETE_FAILED"] ->
        {:error, {:harness_failed, s}}

      {:ok, %{"harness" => %{"status" => _}}} when polls_left > 0 ->
        Process.sleep(@ready_poll_ms)
        wait_until_ready(get_fun, hid, polls_left - 1)

      {:ok, _} ->
        {:error, :harness_ready_timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end
```

> The injected `get_fun`/`list_fun` seams make the READY-poll testable without `Process.sleep` (the test's `get_fun` returns `READY` immediately). `Client` is already aliased in this module.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/req_managed_agents/providers/bedrock_agent_core_test.exs`
Expected: PASS.

- [ ] **Step 5: Full suite + warnings**

Run: `mix compile --warnings-as-errors && mix test`
Expected: PASS, no warnings.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(bedrock): provision/teardown — create harness, READY-poll, 409 reuse, delete

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
jj new
```

---

### Task 3: ClaudeManagedAgents provision/teardown + conformance

**Files:**
- Modify: `lib/req_managed_agents/providers/claude_managed_agents.ex`
- Test: `test/req_managed_agents/providers/claude_managed_agents_test.exs`
- Modify: `test/req_managed_agents/provider_conformance_test.exs`

**Interfaces:**
- Consumes: `ReqManagedAgents.Client.{create_agent/2, create_environment/2, archive_agent/2, archive_environment/2}` — `create_*` return `{:ok, %{"id" => id}}`; `archive_*` return `{:ok, _}`. `Client.new/1` builds a client; `req_options: [plug: {Req.Test, Name}]` injects a stub.
- Produces: `ClaudeManagedAgents.provision(spec, opts) :: {:ok, %{agent_id, environment_id}} | {:error, term()}`; `teardown(%{agent_id, environment_id}, opts) :: :ok | {:error, term()}`.

- [ ] **Step 1: Write the failing test** — add to `test/req_managed_agents/providers/claude_managed_agents_test.exs`

```elixir
  alias ReqManagedAgents.Providers.ClaudeManagedAgents, as: P
  alias ReqManagedAgents.Client

  @spec_claude %{system_prompt: "sys", tools: [%{"name" => "t"}], terminal_tool: nil, model_config: "claude-opus-4-8"}

  defp claude_client(name), do: Client.new(api_key: "sk-test", req_options: [plug: {Req.Test, name}])

  test "provision/2 creates an agent + environment and returns both ids" do
    client = claude_client(__MODULE__.Provision)

    Req.Test.stub(__MODULE__.Provision, fn conn ->
      case conn.request_path do
        "/v1/agents" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)
          assert decoded["model"] == "claude-opus-4-8"
          assert decoded["system"] == "sys"
          Req.Test.json(conn, %{"id" => "agent_1"})

        "/v1/environments" ->
          Req.Test.json(conn, %{"id" => "env_1"})
      end
    end)

    assert {:ok, %{agent_id: "agent_1", environment_id: "env_1"}} =
             P.provision(@spec_claude, client: client)
  end

  test "teardown/2 archives the agent and the environment" do
    client = claude_client(__MODULE__.Teardown)
    {:ok, paths} = Agent.start_link(fn -> [] end)

    Req.Test.stub(__MODULE__.Teardown, fn conn ->
      Agent.update(paths, &[conn.request_path | &1])
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert :ok = P.teardown(%{agent_id: "agent_1", environment_id: "env_1"}, client: client)
    assert Enum.sort(Agent.get(paths, & &1)) ==
             ["/v1/agents/agent_1/archive", "/v1/environments/env_1/archive"]
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/req_managed_agents/providers/claude_managed_agents_test.exs`
Expected: FAIL — `ClaudeManagedAgents.provision/2` undefined.

- [ ] **Step 3: Implement provision/teardown** — add to `lib/req_managed_agents/providers/claude_managed_agents.ex`

```elixir
  @impl true
  def provision(spec, opts) do
    client = opts[:client] || Client.new()
    name = opts[:name] || "agent_#{spec_digest(spec)}"

    agent_body = %{name: name, model: spec.model_config, system: spec.system_prompt, tools: spec.tools}
    env_body = opts[:environment] || %{name: "#{name}_env", config: %{type: "cloud", networking: %{type: "unrestricted"}}}

    with {:ok, %{"id" => agent_id}} <- Client.create_agent(client, agent_body),
         {:ok, %{"id" => env_id}} <- Client.create_environment(client, env_body) do
      {:ok, %{agent_id: agent_id, environment_id: env_id}}
    end
  end

  @impl true
  def teardown(%{agent_id: aid, environment_id: eid}, opts) do
    client = opts[:client] || Client.new()

    with {:ok, _} <- Client.archive_agent(client, aid),
         {:ok, _} <- Client.archive_environment(client, eid) do
      :ok
    end
  end

  defp spec_digest(spec),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(spec)) |> Base.encode16(case: :lower) |> binary_part(0, 8)
```

> `Client` is already aliased in this module. `create_agent`/`create_environment` bodies follow the shape used in `examples/local_tool_example.exs` (name + model + system + tools; name + config). The deterministic `name` keeps provisioning idempotent against the in-process cache; override via `opts[:name]` / `opts[:environment]`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/req_managed_agents/providers/claude_managed_agents_test.exs`
Expected: PASS.

- [ ] **Step 5: Extend the conformance test** — `test/req_managed_agents/provider_conformance_test.exs`

Add `{:provision, 2}` to the `@shared` list, and a teardown assertion to each provider test:

```elixir
  @shared [{:mode, 0}, {:open, 2}, {:kickoff_input, 1}, {:user_input, 1}, {:resume_input, 2}, {:normalize, 1}, {:provision, 2}]
```

In **both** provider tests, after the existing `for` loop, add:

```elixir
    assert function_exported?(BedrockAgentCore, :teardown, 2), "BedrockAgentCore missing teardown/2"
```

(and the analogous `ClaudeManagedAgents` line in its test).

- [ ] **Step 6: Full suite + warnings (default + seed 0)**

Run: `mix compile --warnings-as-errors && mix test && mix test --seed 0`
Expected: PASS both seeds.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(claude): provision/teardown (agent+environment) + provider conformance for provisioning

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
jj new
```

---

## Out of scope (separate spec/plan)

- Exposing the canonical last-turn outcome (`text`/`custom_tool_uses`/`server_tool_uses`) and token
  `usage` on the `Session` result.
- biai-managed-agents' adapter slim-down (deleting its `default_create`/`wait_until_ready`/naming and
  calling `ReqManagedAgents.provision/3`). That migration lands in biai, after this ships.

## Verification checklist (run after Task 3)

- `mix compile --warnings-as-errors` clean; `mix test` + `mix test --seed 0` green.
- `function_exported?/3`: both providers export `provision/2` and `teardown/2`.
- A provisioned handle splats into `Session.run/2` opts unchanged (Bedrock `harness_arn`, Claude
  `agent_id`+`environment_id`).
