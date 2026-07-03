# RMA 0.4 — Environment Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v0.4.0 — pluggable/persistent Provisioner stores, environments as content-addressed images (ensure/tag/resolve/prune), and spike-gated declarative runtimes.

**Architecture:** Image semantics govern everything: spec-hash = digest = identity; `ensure` is a cached build; tags are Store-backed movable pointers; `prune` is the only destruction and is explicit. The `Store` behaviour (4 callbacks) replaces inline ETS in `Provisioner`; `ensure_environment` composes `Client.create_environment`/`list_environments` under digest naming with empty-store recovery; runtimes join the env spec (hash-covered) with realization pinned by a live spike before any dependent task runs.

**Tech Stack:** Elixir, ExUnit, Jason (Store.File), injected client fns (env tests), Req.Test/Bypass per existing conventions.

**Spec:** `docs/superpowers/specs/2026-07-03-rma-040-environment-lifecycle-design.md`

## Global Constraints

- **jj, not git**: `jj describe -m '<msg>' && jj new`. Implementer preflight: `jj log -r '@-' --no-pager -T 'commit_id.short()'` MUST print the SHA the dispatch names — else STOP/BLOCKED. Only jj commands allowed: preflight + final commit.
- **Behavior freeze:** default (no `:store` opt) paths are byte-identical to today — same ETS table name, same hash, same `ensure/3`/`evict/1` contracts. All existing tests pass unmodified.
- **Store contract:** callbacks `get(store_opts, key) :: {:ok, term} | :miss`, `put(store_opts, key, value) :: :ok`, `delete(store_opts, key) :: :ok`, `delete_value(store_opts, value) :: :ok` (4th callback added vs GH #32 because `evict/1` is value-keyed today). Keys namespaced by callers: `"provision:" <> hash`, `"tag:" <> base <> ":" <> tag`.
- **Store failures loud-but-safe:** `get` errors → treated as `:miss` + `Logger.warning`; `put`/`delete` failures → log + proceed (provisioning truth beats cache truth).
- **Image rules:** env name = `<base>_<digest8>` (`digest8` = first 8 lowercase hex of the existing sha256 derivation over the env spec); no `on_drift` anywhere; nothing auto-archives; `prune` requires explicit `keep:`; tagged digests are never pruned; `resolve` never falls back.
- **No MIM-refs in lib/ moduledocs or CHANGELOG.** Gates per task: `mix format && mix test && mix credo --strict` (0 failures, no warnings, "found no issues").
- **Spike gate (MIM-71):** no task may depend on the cloud attachment mechanism before Task 7's live finding is folded back into the spec by the controller.

## PR Phases (pause for user merge between PRs)

| PR | Scope | Tasks | Closes |
|---|---|---|---|
| **PR 1 — Store** | MIM-69 | 1, 2, QA-A | `Closes MIM-69` + `Closes #32` |
| **PR 2 — environments as images** | MIM-70 | 3, 4, 5, QA-B | `Closes MIM-70` + `Closes #33` |
| **PR 3 — runtimes + release** | MIM-71, canary discipline, v0.4.0 | 6, [7 spike — controller-coordinated], 8, 9, 10, QA-C, 11 | `Closes MIM-71` + `Closes #36` |

Each PR branches from the previous phase's merged main (`jj git fetch && jj new <gh-verified sha>`). CHANGELOG's whole v0.4.0 section lands in Task 10 (PR 3).

---

### Task 1: `Store` behaviour + `Store.ETS` + Provisioner threading (behavior-identical)

**Files:**
- Create: `lib/req_managed_agents/provisioner/store.ex`, `lib/req_managed_agents/provisioner/store/ets.ex`
- Modify: `lib/req_managed_agents/provisioner.ex`
- Test: `test/req_managed_agents/provisioner/store_contract_test.exs` (new; shared contract module used again in Task 2), `test/req_managed_agents/provisioning_test.exs` (append `:store` threading test)

**Interfaces:**
- Produces: the 4-callback behaviour (Global Constraints); `Store.ETS` with `store_opts = table_name_atom` (default `:req_managed_agents_provisions`); `Provisioner.ensure(provider, spec, opts)` honoring `opts[:store] :: {module, store_opts}` (default `{Store.ETS, :req_managed_agents_provisions}`); `evict(handle, opts \\ [])` gaining the same `:store` opt; keys now `"provision:" <> hash`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/req_managed_agents/provisioner/store_contract_test.exs
defmodule ReqManagedAgents.Provisioner.StoreContractTest do
  use ExUnit.Case, async: true

  defmodule Contract do
    # Shared contract: call with an impl + a fresh store_opts factory.
    def run(impl, store_opts) do
      assert :miss = impl.get(store_opts, "provision:absent")
      assert :ok = impl.put(store_opts, "provision:k1", %{"id" => "a"})
      assert {:ok, %{"id" => "a"}} = impl.get(store_opts, "provision:k1")
      assert :ok = impl.put(store_opts, "provision:k1", %{"id" => "b"})
      assert {:ok, %{"id" => "b"}} = impl.get(store_opts, "provision:k1")
      assert :ok = impl.put(store_opts, "tag:base:prod", "deadbeef")
      assert {:ok, "deadbeef"} = impl.get(store_opts, "tag:base:prod")
      assert :ok = impl.delete(store_opts, "provision:k1")
      assert :miss = impl.get(store_opts, "provision:k1")
      assert :ok = impl.delete(store_opts, "provision:never-existed")
      assert :ok = impl.put(store_opts, "provision:k2", %{"id" => "victim"})
      assert :ok = impl.put(store_opts, "provision:k3", %{"id" => "survivor"})
      assert :ok = impl.delete_value(store_opts, %{"id" => "victim"})
      assert :miss = impl.get(store_opts, "provision:k2")
      assert {:ok, %{"id" => "survivor"}} = impl.get(store_opts, "provision:k3")
    end
  end

  test "Store.ETS satisfies the contract" do
    table = :"store_contract_#{System.unique_integer([:positive])}"
    Contract.run(ReqManagedAgents.Provisioner.Store.ETS, table)
  end
end
```

Append to `test/req_managed_agents/provisioning_test.exs` (read the file first; reuse its existing fake provider — it provisions via injected/fake `provision/2`):

```elixir
  test "ensure/3 honors a custom :store and evict/1 clears it" do
    table = :"custom_store_#{System.unique_integer([:positive])}"
    store = {ReqManagedAgents.Provisioner.Store.ETS, table}

    # First ensure provisions and records in the CUSTOM store...
    {:ok, handle} = ReqManagedAgents.Provisioner.ensure(FakeProvider, %{n: 1}, store: store)
    # ...second ensure hits the custom store (fake provider would raise/return a
    # DIFFERENT handle on a second real provision — assert same handle back).
    {:ok, ^handle} = ReqManagedAgents.Provisioner.ensure(FakeProvider, %{n: 1}, store: store)

    :ok = ReqManagedAgents.Provisioner.evict(handle, store: store)
    # After evict, ensure must provision again (fake yields a fresh handle).
    {:ok, handle2} = ReqManagedAgents.Provisioner.ensure(FakeProvider, %{n: 1}, store: store)
    refute handle2 == handle
  end
```

(Adapt `FakeProvider` to whatever the file already defines — if its fake returns deterministic handles, extend the fake with a counter via `:counters`/process dictionary so re-provision is observable. Keep the existing tests untouched.)

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/req_managed_agents/provisioner/store_contract_test.exs test/req_managed_agents/provisioning_test.exs`
Expected: FAIL — `Store.ETS` undefined; `ensure/3` ignores `:store` / `evict/2` undefined.

- [ ] **Step 3: Implement**

```elixir
# lib/req_managed_agents/provisioner/store.ex
defmodule ReqManagedAgents.Provisioner.Store do
  @moduledoc """
  Storage behaviour for the provision cache: where `{spec-hash → handle}` and
  tag pointers live. `ReqManagedAgents.Provisioner.Store.ETS` (default) keeps
  today's in-process semantics; `ReqManagedAgents.Provisioner.Store.File`
  persists across OS processes for CLI/mix-task/cron consumers.

  Keys are namespaced strings (`"provision:" <> hash`, `"tag:" <> base <> ":" <> tag`).
  `delete_value/2` exists because eviction is value-keyed (a teardown holds the
  handle, not the key).
  """
  @callback get(store_opts :: term(), key :: String.t()) :: {:ok, term()} | :miss
  @callback put(store_opts :: term(), key :: String.t(), value :: term()) :: :ok
  @callback delete(store_opts :: term(), key :: String.t()) :: :ok
  @callback delete_value(store_opts :: term(), value :: term()) :: :ok
end
```

```elixir
# lib/req_managed_agents/provisioner/store/ets.ex
defmodule ReqManagedAgents.Provisioner.Store.ETS do
  @moduledoc """
  Default in-process store — a named public ETS table. Process-independent
  within one BEAM; empty in every fresh OS process (the original cache
  semantics, unchanged).
  """
  @behaviour ReqManagedAgents.Provisioner.Store

  @impl true
  def get(table, key) do
    case :ets.lookup(ensure_table(table), key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  end

  @impl true
  def put(table, key, value) do
    :ets.insert(ensure_table(table), {key, value})
    :ok
  end

  @impl true
  def delete(table, key) do
    :ets.delete(ensure_table(table), key)
    :ok
  end

  @impl true
  def delete_value(table, value) do
    :ets.match_delete(ensure_table(table), {:"$1", value})
    :ok
  end

  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined -> :ets.new(table, [:named_table, :public, :set])
      _ref -> table
    end
  end
end
```

Rewrite `lib/req_managed_agents/provisioner.ex` (moduledoc: keep the first two sentences, replace the ETS sentence with the store story; NO ticket refs):

```elixir
defmodule ReqManagedAgents.Provisioner do
  @moduledoc """
  Hash-keyed provision cache. `ensure/3` returns a cached provider `handle` for a given
  `{provider, spec}`, calling `provider.provision/2` only on a miss. The handle is the
  durable artifact; where the `{hash → handle}` mapping lives is pluggable via the
  `ReqManagedAgents.Provisioner.Store` behaviour (`:store` option) — in-process ETS by
  default, or a persistent store (e.g. `Store.File`) for reuse across OS processes.
  """
  require Logger
  alias ReqManagedAgents.Provider
  alias ReqManagedAgents.Provisioner.Store

  @default_store {Store.ETS, :req_managed_agents_provisions}

  @spec ensure(module(), Provider.spec(), keyword()) ::
          {:ok, Provider.handle()} | {:error, term()}
  def ensure(provider, spec, opts \\ []) do
    {mod, sopts} = opts[:store] || @default_store
    key = "provision:" <> hash({provider, spec})

    case safe_get(mod, sopts, key) do
      {:ok, handle} ->
        {:ok, handle}

      :miss ->
        case provider.provision(spec, opts) do
          {:ok, handle} ->
            safe_put(mod, sopts, key, handle)
            {:ok, handle}

          {:error, reason} ->
            {:error, {:provision_failed, reason}}
        end
    end
  end

  @doc "Drop any cache entry whose value is `handle` (called after teardown)."
  @spec evict(Provider.handle(), keyword()) :: :ok
  def evict(handle, opts \\ []) do
    {mod, sopts} = opts[:store] || @default_store
    mod.delete_value(sopts, handle)
    :ok
  end

  @doc false
  def reset do
    {_mod, table} = @default_store
    if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    :ok
  end

  @doc false
  def hash(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic])) |> Base.encode16()

  # A broken cache must not block provisioning (loud-but-safe).
  defp safe_get(mod, sopts, key) do
    mod.get(sopts, key)
  rescue
    e ->
      Logger.warning("provision store get failed (treating as miss): #{inspect(e)}")
      :miss
  end

  defp safe_put(mod, sopts, key, value) do
    mod.put(sopts, key, value)
  rescue
    e -> Logger.warning("provision store put failed (handle still returned): #{inspect(e)}")
  end
end
```

Note `hash/1` becomes `@doc false` public — Task 3 reuses it. `evict/1` keeps working (default arg). The old bare-hash ETS keys are simply orphaned (fresh key namespace; cache-only data, no migration needed) — but the table name is unchanged so `reset/0` still clears everything.

- [ ] **Step 4: Run new + full suite**

Run: `mix test test/req_managed_agents/provisioner/store_contract_test.exs test/req_managed_agents/provisioning_test.exs && mix format && mix test && mix credo --strict`
Expected: ALL PASS; every pre-existing provisioning/facade/live-events test green unmodified.

- [ ] **Step 5: Commit**

```bash
jj describe -m 'feat(provisioner): pluggable Store behaviour — ETS default extracted, :store threading (MIM-69)' && jj new
```

---

### Task 2: `Store.File`

**Files:**
- Create: `lib/req_managed_agents/provisioner/store/file.ex`
- Test: `test/req_managed_agents/provisioner/store_file_test.exs` (new; reuses the Contract module)

**Interfaces:**
- Consumes: Task 1's behaviour + Contract test module.
- Produces: `Store.File` with `store_opts :: [path: String.t()]`; JSON persistence, atomic writes, corrupt→empty+warn. Tasks 4/5 use it in tag/prune tests.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/req_managed_agents/provisioner/store_file_test.exs
defmodule ReqManagedAgents.Provisioner.StoreFileTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias ReqManagedAgents.Provisioner.Store

  setup do
    dir = System.tmp_dir!() |> Path.join("rma_store_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, path: Path.join(dir, "provisions.json")}
  end

  test "satisfies the store contract", %{path: path} do
    ReqManagedAgents.Provisioner.StoreContractTest.Contract.run(Store.File, path: path)
  end

  test "persists across store instances (fresh-OS-process simulation)", %{path: path} do
    assert :ok = Store.File.put([path: path], "provision:h1", %{"environment_id" => "env_1"})
    # A "new process" is just a new call with the same path — nothing in-memory.
    assert {:ok, %{"environment_id" => "env_1"}} = Store.File.get([path: path], "provision:h1")
  end

  test "missing file is empty, not an error", %{path: path} do
    assert :miss = Store.File.get([path: path], "provision:none")
  end

  test "corrupt file is treated as empty with a logged warning", %{path: path} do
    File.write!(path, "{not json!!")

    log =
      capture_log(fn ->
        assert :miss = Store.File.get([path: path], "provision:x")
      end)

    assert log =~ "corrupt"
    # And a subsequent put recovers the file.
    assert :ok = Store.File.put([path: path], "provision:x", %{"a" => 1})
    assert {:ok, %{"a" => 1}} = Store.File.get([path: path], "provision:x")
  end

  test "writes are atomic — no partial JSON visible at the path", %{path: path} do
    for i <- 1..50, do: :ok = Store.File.put([path: path], "provision:k#{i}", %{"i" => i})
    # If writes were non-atomic, an interleaved reader could see partial JSON;
    # at minimum the final file must parse and hold all keys.
    assert {:ok, %{"i" => 50}} = Store.File.get([path: path], "provision:k50")
    assert {:ok, %{"i" => 1}} = Store.File.get([path: path], "provision:k1")
    assert {:ok, _} = Jason.decode(File.read!(path))
  end
end
```

- [ ] **Step 2: Run to verify failure** — `Store.File` undefined.

- [ ] **Step 3: Implement**

```elixir
# lib/req_managed_agents/provisioner/store/file.ex
defmodule ReqManagedAgents.Provisioner.Store.File do
  @moduledoc """
  Persistent JSON-file store: provision handles and tags survive OS-process
  restarts (CLI tools, mix tasks, cron). One flat JSON object per file;
  writes are atomic (temp file + rename). **Single-writer assumption**: this
  is a workstation/task-runner store, not a concurrent-fleet store. A missing
  or corrupt file is treated as empty (with a logged warning) — the durable
  provider resources are recoverable regardless.

  Values must be JSON-encodable (provision handles are plain maps; atom keys
  round-trip as strings, which is fine for handle maps read back via
  string-keyed access — store consumers in this library only ever compare
  whole values or read string keys).
  """
  @behaviour ReqManagedAgents.Provisioner.Store
  require Logger

  @impl true
  def get(opts, key) do
    case Map.fetch(read(path!(opts)), key) do
      {:ok, value} -> {:ok, value}
      :error -> :miss
    end
  end

  @impl true
  def put(opts, key, value) do
    path = path!(opts)
    write(path, Map.put(read(path), key, normalize(value)))
  end

  @impl true
  def delete(opts, key) do
    path = path!(opts)
    write(path, Map.delete(read(path), key))
  end

  @impl true
  def delete_value(opts, value) do
    path = path!(opts)
    norm = normalize(value)
    write(path, read(path) |> Enum.reject(fn {_k, v} -> v == norm end) |> Map.new())
  end

  defp path!(opts), do: Keyword.fetch!(opts, :path)

  # Values round-trip through JSON; normalize on write so delete_value/2
  # comparisons match what get/2 returns (string keys).
  defp normalize(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp read(path) do
    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{} = map} ->
            map

          _ ->
            Logger.warning("provision store file corrupt, treating as empty: #{path}")
            %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("provision store file unreadable (#{inspect(reason)}), treating as empty: #{path}")
        %{}
    end
  end

  defp write(path, map) do
    tmp = path <> ".tmp.#{System.unique_integer([:positive])}"
    File.write!(tmp, Jason.encode!(map))
    :ok = File.rename(tmp, path)
    :ok
  end
end
```

**Contract-vs-JSON note for the implementer:** the shared Contract asserts a value with string keys (`%{"id" => "a"}`) — JSON round-trip preserves it exactly, so the contract passes for both impls. The `normalize/1`-on-write rule is what makes `delete_value/2` correct after restarts.

- [ ] **Step 4: Run new tests + full suite + gates; Step 5: Commit**

```bash
jj describe -m 'feat(provisioner): Store.File — persistent JSON store, atomic writes, corrupt-safe (MIM-69)' && jj new
```

---

### QA-CHECKPOINT A (closes PR 1) — Store end-to-end

qa-tester authors + executes `docs/qa/<date>-provisioner-store-manual-test.md`. Scenarios: contract on both impls; a REAL cross-OS-process reuse proof (two separate `mix run` invocations sharing a Store.File path — second must not re-provision, observed via an injected provision fun that writes a sentinel); evict-by-value with duplicated handles under two keys (both go — document); store with unwritable path (put failure → warning + handle still returned, per loud-but-safe); corrupt-mid-file recovery; `:store` default untouched (existing ETS behavior byte-identical — rerun one pre-existing provisioning test file and say which). Gates incl. `mix credo --strict`. Then bookmark `ryan/mim-69-provisioner-store`, PR 1 (`Closes #32` / last line `Closes MIM-69`). PAUSE for merge.

---

### Task 3: `ensure_environment/3` — environments as images

**Files:**
- Create: `lib/req_managed_agents/provisioner/environments.ex`
- Modify: `lib/req_managed_agents/provisioner.ex` (defdelegates), `lib/req_managed_agents.ex` (facade), `lib/req_managed_agents/client/behaviour.ex` (verify `archive_environment` present — it is; no change expected)
- Test: `test/req_managed_agents/provisioner/environments_test.exs` (new)

**Interfaces:**
- Consumes: Task 1's store plumbing + `Provisioner.hash/1`; `Client.create_environment/2`, `list_environments/2`, `archive_environment/2` via injected fns (`:create_fun`, `:list_fun` opts — provider-test convention).
- Produces: `Provisioner.ensure_environment(client, env_spec, opts)` → `{:ok, %{environment_id: id, name: name, digest: digest}}`; `opts`: `:name` (base, default `"env"`), `:store`, `:create_fun`, `:list_fun`. Digest = `String.downcase(binary_part(hash(env_spec), 0, 8))`. Env name `<base>_<digest>`. Facade `ReqManagedAgents.ensure_environment/3`. Tasks 4/5/8/9 consume all of this.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/req_managed_agents/provisioner/environments_test.exs
defmodule ReqManagedAgents.Provisioner.EnvironmentsTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Provisioner
  alias ReqManagedAgents.Provisioner.Store

  @spec1 %{type: :cloud, packages: %{pip: ["pandas"]}, networking: %{type: :unrestricted}}
  @spec2 %{type: :cloud, packages: %{pip: ["pandas", "numpy"]}, networking: %{type: :unrestricted}}

  defp fresh_store do
    {Store.ETS, :"env_store_#{System.unique_integer([:positive])}"}
  end

  test "digest-named create on miss; identical spec is a pure cache hit" do
    test_pid = self()

    create_fun = fn body ->
      send(test_pid, {:create, body})
      {:ok, %{"id" => "env_123", "name" => body.name}}
    end

    store = fresh_store()

    assert {:ok, %{environment_id: "env_123", name: name, digest: digest}} =
             Provisioner.ensure_environment(:client, @spec1,
               name: "data_analysis",
               store: store,
               create_fun: create_fun,
               list_fun: fn -> flunk("list must not be called when store hits/creates") end
             )

    assert name == "data_analysis_" <> digest
    assert digest =~ ~r/^[0-9a-f]{8}$/
    assert_received {:create, %{name: ^name}}

    # Second ensure: store hit — NO create, NO list.
    assert {:ok, %{environment_id: "env_123"}} =
             Provisioner.ensure_environment(:client, @spec1,
               name: "data_analysis",
               store: store,
               create_fun: fn _ -> flunk("must not re-create on hit") end,
               list_fun: fn -> flunk("must not list on hit") end
             )

    refute_received {:create, _}
  end

  test "different spec = different image (different digest-name), ensured alongside" do
    store = fresh_store()
    create_fun = fn body -> {:ok, %{"id" => "env_" <> body.name, "name" => body.name}} end

    {:ok, %{name: n1}} =
      Provisioner.ensure_environment(:c, @spec1, name: "d", store: store, create_fun: create_fun)

    {:ok, %{name: n2}} =
      Provisioner.ensure_environment(:c, @spec2, name: "d", store: store, create_fun: create_fun)

    refute n1 == n2
  end

  test "empty store recovers by exact digest-name via list (409 or fresh machine)" do
    digest_name_holder = :ets.new(:t, [:public])

    create_fun = fn body ->
      :ets.insert(digest_name_holder, {:name, body.name})
      {:error, {:http_error, 409, %{"error" => "exists"}}}
    end

    list_fun = fn ->
      [{:name, name}] = :ets.lookup(digest_name_holder, :name)
      {:ok, %{"data" => [%{"id" => "env_recovered", "name" => name, "archived_at" => nil}]}}
    end

    assert {:ok, %{environment_id: "env_recovered"}} =
             Provisioner.ensure_environment(:c, @spec1,
               name: "d", store: fresh_store(), create_fun: create_fun, list_fun: list_fun)
  end

  test "archived environments are treated as absent in recovery" do
    create_count = :counters.new(1, [])

    create_fun = fn body ->
      :counters.add(create_count, 1, 1)

      case :counters.get(create_count, 1) do
        1 -> {:error, {:http_error, 409, %{}}}
        2 -> {:ok, %{"id" => "env_new", "name" => body.name}}
      end
    end

    list_fun = fn ->
      {:ok, %{"data" => [%{"id" => "env_old", "name" => "d_ignored", "archived_at" => "2026-01-01T00:00:00Z"}]}}
    end

    # 409 + only-archived match -> retry create once more? NO — per design the
    # 409 name IS the digest name; if list shows only archived matches, surface
    # a clear error (the operator archived this exact image; re-creating with
    # the same name will keep 409ing on some providers). Expect:
    assert {:error, {:environment_archived, _name}} =
             Provisioner.ensure_environment(:c, @spec1,
               name: "d", store: fresh_store(), create_fun: create_fun, list_fun: list_fun)
  end

  test "provider errors pass through" do
    assert {:error, {:http_error, 500, _}} =
             Provisioner.ensure_environment(:c, @spec1,
               name: "d",
               store: fresh_store(),
               create_fun: fn _ -> {:error, {:http_error, 500, %{}}} end)
  end
end
```

- [ ] **Step 2: Run to verify failure** — `ensure_environment/3` undefined.

- [ ] **Step 3: Implement**

```elixir
# lib/req_managed_agents/provisioner/environments.ex
defmodule ReqManagedAgents.Provisioner.Environments do
  @moduledoc """
  Environments as immutable images: content-addressed by spec digest, built
  once, reused forever, superseded by NEW images (never mutated), destroyed
  only by explicit prune.

  The provider-side name is `<base>_<digest8>` — `repo@digest` — so a name
  collision can only ever mean "this exact image already exists", and recovery
  by name is definitionally version-correct even with an empty store.
  """
  require Logger
  alias ReqManagedAgents.Provisioner
  alias ReqManagedAgents.Provisioner.Store

  @default_store {Store.ETS, :req_managed_agents_provisions}

  @doc """
  Build-if-absent for an environment image. Returns
  `{:ok, %{environment_id: id, name: name, digest: digest}}`.

  Opts: `:name` (repository base, default `"env"`), `:store`
  (`{module, store_opts}`), `:create_fun` / `:list_fun` (test seams; default
  to `ReqManagedAgents.Client` calls on the given client).
  """
  def ensure_environment(client, env_spec, opts \\ []) do
    base = opts[:name] || "env"
    digest = env_spec |> Provisioner.hash() |> binary_part(0, 8) |> String.downcase()
    name = base <> "_" <> digest
    {smod, sopts} = opts[:store] || @default_store
    key = "provision:env:" <> Provisioner.hash({base, env_spec})

    create_fun =
      opts[:create_fun] ||
        fn body -> ReqManagedAgents.Client.create_environment(client, body) end

    list_fun =
      opts[:list_fun] || fn -> ReqManagedAgents.Client.list_environments(client, %{}) end

    case store_get(smod, sopts, key) do
      {:ok, handle} ->
        {:ok, atomize_handle(handle)}

      :miss ->
        build(create_fun, list_fun, env_spec, name, digest)
        |> case do
          {:ok, handle} ->
            store_put(smod, sopts, key, handle)
            {:ok, handle}

          error ->
            error
        end
    end
  end

  defp build(create_fun, list_fun, env_spec, name, digest) do
    body = %{name: name, config: wire_config(env_spec)}

    case create_fun.(body) do
      {:ok, %{"id" => id}} ->
        {:ok, %{environment_id: id, name: name, digest: digest}}

      {:error, {:http_error, 409, _}} ->
        recover(list_fun, name, digest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recover(list_fun, name, digest) do
    with {:ok, %{"data" => envs}} <- list_fun.() do
      live = Enum.find(envs, &(&1["name"] == name and is_nil(&1["archived_at"])))
      archived = Enum.find(envs, &(&1["name"] == name))

      cond do
        live -> {:ok, %{environment_id: live["id"], name: name, digest: digest}}
        archived -> {:error, {:environment_archived, name}}
        true -> {:error, {:environment_name_conflict, name}}
      end
    end
  end

  # The env spec is opaque beyond hashing; the wire `config` is the spec minus
  # our own bookkeeping keys (currently none to strip — pass through).
  defp wire_config(env_spec), do: env_spec

  # Store.File round-trips handles through JSON (string keys) — re-atomize the
  # three known fields so callers get one shape from either store.
  defp atomize_handle(%{environment_id: _} = h), do: h

  defp atomize_handle(%{"environment_id" => id, "name" => n, "digest" => d}),
    do: %{environment_id: id, name: n, digest: d}

  defp store_get(mod, sopts, key) do
    mod.get(sopts, key)
  rescue
    e ->
      Logger.warning("environment store get failed (treating as miss): #{inspect(e)}")
      :miss
  end

  defp store_put(mod, sopts, key, value) do
    mod.put(sopts, key, value)
  rescue
    e -> Logger.warning("environment store put failed (handle still returned): #{inspect(e)}")
  end
end
```

Add to `lib/req_managed_agents/provisioner.ex`:

```elixir
  defdelegate ensure_environment(client, env_spec, opts \\ []),
    to: ReqManagedAgents.Provisioner.Environments
```

Add to `lib/req_managed_agents.ex` (after `provision/3`, matching its doc style):

```elixir
  @doc """
  Build-if-absent for an environment image (Claude Managed Agents): content-addressed
  by spec digest, named `<base>_<digest8>`, reused on every identical spec. See
  `ReqManagedAgents.Provisioner.Environments`.
  """
  defdelegate ensure_environment(client, env_spec, opts \\ []),
    to: ReqManagedAgents.Provisioner.Environments
```

- [ ] **Step 4: Gates; Step 5: Commit**

```bash
jj describe -m 'feat(provisioner): ensure_environment — content-addressed environment images (MIM-70)' && jj new
```

---

### Task 4: tags — `tag/4` + `resolve/2`

**Files:**
- Modify: `lib/req_managed_agents/provisioner/environments.ex`, `lib/req_managed_agents/provisioner.ex` (defdelegates)
- Test: `test/req_managed_agents/provisioner/environments_test.exs` (append)

**Interfaces:**
- Produces: `tag(base, tag, digest_or_handle, opts)` → `:ok` (writes `"tag:" <> base <> ":" <> tag` → digest string); `resolve(ref, opts)` where `ref = "base:tag"` → `{:ok, handle} | {:error, :unknown_tag} | {:error, {:untracked_digest, digest}}`. Task 5's prune consumes tag enumeration via the documented key convention... **correction:** the 3+1-callback store cannot enumerate keys. Prune therefore reads tags from an explicit tag REGISTRY entry: `tag/4` also maintains `"tags:" <> base` → `%{tag => digest}` map (single key, read-modify-write, single-writer store assumption). `resolve/2` and Task 5 read that registry.

- [ ] **Step 1: Write the failing tests (append)**

```elixir
  describe "tags" do
    test "tag + resolve round-trip via the registry entry" do
      store = fresh_store()
      create_fun = fn body -> {:ok, %{"id" => "env_t1", "name" => body.name}} end

      {:ok, %{digest: digest} = handle} =
        Provisioner.ensure_environment(:c, @spec1, name: "d", store: store, create_fun: create_fun)

      assert :ok = Provisioner.tag("d", "prod", handle, store: store)
      assert {:ok, resolved} = Provisioner.resolve("d:prod", store: store)
      assert resolved.environment_id == handle.environment_id

      # Retag to another digest moves the pointer.
      {:ok, h2} =
        Provisioner.ensure_environment(:c, @spec2, name: "d", store: store, create_fun: create_fun)

      assert :ok = Provisioner.tag("d", "prod", h2, store: store)
      assert {:ok, r2} = Provisioner.resolve("d:prod", store: store)
      assert r2.environment_id == h2.environment_id
      refute r2.environment_id == handle.environment_id

      # The registry holds both mappings' history? No — one tag, latest digest only.
      assert {:error, :unknown_tag} = Provisioner.resolve("d:staging", store: store)
      # digest is a plain 8-hex string
      assert digest =~ ~r/^[0-9a-f]{8}$/
    end

    test "resolve of a tag whose digest lost its provision entry is :untracked_digest" do
      store = {mod, sopts} = fresh_store()
      create_fun = fn body -> {:ok, %{"id" => "env_x", "name" => body.name}} end

      {:ok, handle} =
        Provisioner.ensure_environment(:c, @spec1, name: "d", store: store, create_fun: create_fun)

      :ok = Provisioner.tag("d", "prod", handle, store: store)
      # Simulate a pruned/evicted provision entry with a surviving tag.
      :ok = mod.delete_value(sopts, handle)

      assert {:error, {:untracked_digest, _}} = Provisioner.resolve("d:prod", store: store)
    end

    test "tag accepts a raw digest string too" do
      store = fresh_store()
      assert :ok = Provisioner.tag("d", "prod", "abcd1234", store: store)
      # No provision entry for it -> untracked on resolve.
      assert {:error, {:untracked_digest, "abcd1234"}} = Provisioner.resolve("d:prod", store: store)
    end
  end
```

- [ ] **Step 2: verify failure. Step 3: Implement (in `Environments`)**

```elixir
  @doc """
  Point `base:tag` at an image digest (or a handle's digest). A movable
  pointer — retagging replaces it. Tagged digests are protected from `prune/3`.
  """
  def tag(base, tag, digest_or_handle, opts \\ []) do
    {smod, sopts} = opts[:store] || @default_store
    digest = to_digest(digest_or_handle)

    registry =
      case store_get(smod, sopts, "tags:" <> base) do
        {:ok, %{} = reg} -> reg
        _ -> %{}
      end

    smod.put(sopts, "tags:" <> base, Map.put(registry, tag, digest))
  end

  @doc """
  Resolve `"base:tag"` to the tagged image's handle. Never falls back:
  `{:error, :unknown_tag}` when the tag doesn't exist,
  `{:error, {:untracked_digest, digest}}` when the tag points at a digest whose
  provision entry is gone (e.g. pruned store) — re-`ensure` the spec to heal.
  """
  def resolve(ref, opts \\ []) do
    {smod, sopts} = opts[:store] || @default_store
    [base, tag] = String.split(ref, ":", parts: 2)

    with {:ok, %{} = registry} <- store_get(smod, sopts, "tags:" <> base),
         {:tag, digest} when is_binary(digest) <- {:tag, registry[tag]},
         {:handle, {:ok, handle}} <- {:handle, find_handle(smod, sopts, base, digest)} do
      {:ok, atomize_handle(handle)}
    else
      :miss -> {:error, :unknown_tag}
      {:tag, nil} -> {:error, :unknown_tag}
      {:handle, :miss} -> {:error, {:untracked_digest, untracked(smod, sopts, base, tag)}}
    end
  end

  defp find_handle(smod, sopts, base, digest) do
    # Provision entries are keyed by full spec hash; the handle carries the
    # digest — scan is not possible via the 4-callback store, so handles are
    # ALSO indexed at ensure time. The index is BASE-scoped ("digest:<base>:<d>")
    # because the digest hashes only the spec: two bases sharing a spec share a
    # digest, and an unscoped index would let resolve return the wrong base's env.
    store_get(smod, sopts, "digest:" <> base <> ":" <> digest)
  end

  defp untracked(smod, sopts, base, tag) do
    case store_get(smod, sopts, "tags:" <> base) do
      {:ok, reg} -> reg[tag]
      _ -> nil
    end
  end

  defp to_digest(%{digest: d}), do: d
  defp to_digest(%{"digest" => d}), do: d
  defp to_digest(d) when is_binary(d), do: d
```

and in `ensure_environment/3`'s success path (both create and store-put arm), ALSO write the digest index:

```elixir
            store_put(smod, sopts, key, handle)
            store_put(smod, sopts, "digest:" <> base <> ":" <> digest, handle)
```

(Also add the base-scoped digest-index write in the recovery arm. Update `atomize_handle` usage accordingly. Add `defdelegate tag/4` + `resolve/2` on `Provisioner`.)

- [ ] **Step 4: Gates. Step 5: Commit**

```bash
jj describe -m 'feat(provisioner): image tags — movable pointers + resolve, digest index (MIM-70)' && jj new
```

---

### Task 5: `prune_environments/3`

**Files:**
- Modify: `lib/req_managed_agents/provisioner/environments.ex`, `lib/req_managed_agents/provisioner.ex` (defdelegate)
- Test: `test/req_managed_agents/provisioner/environments_test.exs` (append)

**Interfaces:**
- Consumes: Task 4's `"tags:" <> base` registry; `list_environments`/`archive_environment` via `:list_fun`/`:archive_fun` seams.
- Produces: `prune_environments(client, base, opts)` — REQUIRES `opts[:keep]` (pos integer) else `{:error, :keep_required}`; keeps the newest `keep` live `<base>_*` versions PLUS every tagged digest; archives the rest via `archive_fun`; deletes their `provision:env:`-side entries by value and their `digest:` index; returns `{:ok, %{archived: [names], kept: [names]}}`; partial failure → `{:error, {:partial, archived_so_far, failed_on}}`.

- [ ] **Step 1: Write the failing tests (append)**

```elixir
  describe "prune" do
    defp env(name, created_at, archived \\ nil),
      do: %{"id" => "id_" <> name, "name" => name, "created_at" => created_at, "archived_at" => archived}

    test "keeps newest N + tagged; archives the rest; :keep is mandatory" do
      store = fresh_store()
      # Tag digest "cccccccc" as prod.
      :ok = Provisioner.tag("d", "prod", "cccccccc", store: store)

      envs = [
        env("d_aaaaaaaa", "2026-07-01T00:00:00Z"),
        env("d_bbbbbbbb", "2026-07-02T00:00:00Z"),
        env("d_cccccccc", "2026-07-03T00:00:00Z"),
        env("d_dddddddd", "2026-07-04T00:00:00Z"),
        env("other_eeeeeeee", "2026-07-04T00:00:00Z"),
        env("d_ffffffff", "2026-06-01T00:00:00Z", "2026-06-02T00:00:00Z")
      ]

      test_pid = self()
      archive_fun = fn id -> send(test_pid, {:archived, id}); {:ok, %{"id" => id}} end
      list_fun = fn -> {:ok, %{"data" => envs}} end

      assert {:error, :keep_required} =
               Provisioner.prune_environments(:c, "d", store: store, list_fun: list_fun)

      assert {:ok, %{archived: archived, kept: kept}} =
               Provisioner.prune_environments(:c, "d",
                 keep: 1, store: store, list_fun: list_fun, archive_fun: archive_fun)

      # newest 1 = d_dddddddd; tagged = d_cccccccc; other_* untouched; already-archived skipped.
      assert Enum.sort(kept) == ["d_cccccccc", "d_dddddddd"]
      assert Enum.sort(archived) == ["d_aaaaaaaa", "d_bbbbbbbb"]
      assert_received {:archived, "id_d_aaaaaaaa"}
      assert_received {:archived, "id_d_bbbbbbbb"}
      refute_received {:archived, "id_other_eeeeeeee"}
    end

    test "partial failure reports progress" do
      store = fresh_store()

      envs = [
        env("d_11111111", "2026-07-01T00:00:00Z"),
        env("d_22222222", "2026-07-02T00:00:00Z"),
        env("d_33333333", "2026-07-03T00:00:00Z")
      ]

      archive_fun = fn
        "id_d_11111111" -> {:ok, %{}}
        "id_d_22222222" -> {:error, {:http_error, 500, %{}}}
      end

      assert {:error, {:partial, ["d_11111111"], {"d_22222222", {:http_error, 500, %{}}}}} =
               Provisioner.prune_environments(:c, "d",
                 keep: 1, store: store,
                 list_fun: fn -> {:ok, %{"data" => envs}} end,
                 archive_fun: archive_fun)
    end
  end
```

- [ ] **Step 2: verify failure. Step 3: Implement**

```elixir
  @doc """
  Explicit image GC: archives `<base>_*` environment versions beyond the newest
  `keep:` (REQUIRED — there is no default for a permanent operation), never
  touching tagged digests or already-archived versions. Returns
  `{:ok, %{archived: names, kept: names}}` or
  `{:error, {:partial, archived_names, {failed_name, reason}}}`.
  """
  def prune_environments(client, base, opts \\ []) do
    with {:keep, keep} when is_integer(keep) and keep > 0 <- {:keep, opts[:keep]} do
      {smod, sopts} = opts[:store] || @default_store

      list_fun =
        opts[:list_fun] || fn -> ReqManagedAgents.Client.list_environments(client, %{}) end

      archive_fun =
        opts[:archive_fun] || fn id -> ReqManagedAgents.Client.archive_environment(client, id) end

      tagged =
        case store_get(smod, sopts, "tags:" <> base) do
          {:ok, reg} -> reg |> Map.values() |> MapSet.new()
          _ -> MapSet.new()
        end

      with {:ok, %{"data" => envs}} <- list_fun.() do
        versions =
          envs
          |> Enum.filter(&(String.starts_with?(&1["name"], base <> "_") and is_nil(&1["archived_at"])))
          |> Enum.sort_by(& &1["created_at"], :desc)

        {kept_by_count, candidates} = Enum.split(versions, keep)

        {tagged_keeps, to_archive} =
          Enum.split_with(candidates, fn e ->
            digest = String.trim_leading(e["name"], base <> "_")
            MapSet.member?(tagged, digest)
          end)

        kept = Enum.map(kept_by_count ++ tagged_keeps, & &1["name"])
        archive_all(to_archive, archive_fun, smod, sopts, base, kept, [])
      end
    else
      {:keep, _} -> {:error, :keep_required}
    end
  end

  defp archive_all([], _fun, _smod, _sopts, _base, kept, archived),
    do: {:ok, %{archived: Enum.reverse(archived), kept: kept}}

  defp archive_all([e | rest], fun, smod, sopts, base, kept, archived) do
    case fun.(e["id"]) do
      {:ok, _} ->
        digest = String.trim_leading(e["name"], base <> "_")
        smod.delete(sopts, "digest:" <> base <> ":" <> digest)
        smod.delete_value(sopts, %{environment_id: e["id"], name: e["name"], digest: digest})
        archive_all(rest, fun, smod, sopts, base, kept, [e["name"] | archived])

      {:error, reason} ->
        {:error, {:partial, Enum.reverse(archived), {e["name"], reason}}}
    end
  end
```

(Also `delete_value` with the string-keyed JSON shape: call it a second time with `%{"environment_id" => …}` — or normalize: simplest correct approach is delete BOTH shapes; note it in a comment. Add the `defdelegate prune_environments/3`.)

- [ ] **Step 4: Gates. Step 5: Commit**

```bash
jj describe -m 'feat(provisioner): prune_environments — explicit image GC, tag-protected, keep-required (MIM-70)' && jj new
```

---

### QA-CHECKPOINT B (closes PR 2) — image lifecycle end-to-end

qa-tester doc `docs/qa/<date>-environment-images-manual-test.md`: full build→hit→tag→retag→resolve→prune story over `Store.File` in a tmp dir with scripted client fns; empty-store recovery; archived-image error; prune matrix (keep-required, tagged protection, partial failure, foreign-base isolation, `base` names containing `_`); untracked-digest resolve; JSON round-trip of handles (string-vs-atom keys through File store — adversarial: ensure with ETS store then resolve with File store and vice versa, document any shape mismatch as code_bug). Then bookmark `ryan/mim-70-environment-images`, PR 2 (`Closes #33` / `Closes MIM-70`). PAUSE for merge.

---

### Task 6: runtimes on the spec surface (offline half of MIM-71)

**Files:**
- Create: `lib/req_managed_agents/provisioner/runtimes.ex`, `priv/runtime_bootstrap/mise_install.sh.eex`, `priv/runtime_bootstrap/allowed_hosts.json`
- Modify: `lib/req_managed_agents/provisioner/environments.ex` (runtimes validation + allowlist merge)
- Test: `test/req_managed_agents/provisioner/runtimes_test.exs` (new)

**Interfaces:**
- Produces: env-spec key `runtimes: [%{lang: atom, version: binary, via: :mise}]` — validated (`{:error, {:invalid_runtime, entry}}` on unknown `via`/missing fields), digest-covered automatically (it's in the spec). `Runtimes.bootstrap_script(runtimes)` → rendered install script binary; `Runtimes.required_hosts(runtimes)` → host list; `ensure_environment` merges hosts into `networking.allowed_hosts` when networking type is `:limited`/`"limited"` and runtimes are present. NO attachment mechanism yet (Task 8, spike-gated).

- [ ] **Step 1: tests** — validation matrix (valid elixir/erlang entries; unknown via rejected; missing version rejected); digest distinction (spec ± runtimes → different `ensure_environment` names, reusing the injected-fns harness); `bootstrap_script/1` renders pinned `mise use --global erlang@…`/`elixir@…` lines + locale exports and is deterministic; `required_hosts/1` returns the allowlist for `:mise`; allowlist merge happens ONLY for limited networking (unrestricted specs unchanged — assert the create body); hosts deduplicated.
- [ ] **Step 2: red. Step 3: implement** — `mise_install.sh.eex` renders from entries (`erlang` before `elixir` when both present; `elixir@<version>-otp-<erlang_major>` when an erlang entry exists, plain `elixir@<version>` otherwise); `allowed_hosts.json` seeded with mise's documented hosts (`mise.jdx.dev`, `github.com`, `objects.githubusercontent.com`, `repo.hex.pm`, `builds.hex.pm`) — a data file, editable without code changes.
- [ ] **Step 4: gates. Step 5: commit** `feat(provisioner): declared runtimes — spec surface, bootstrap rendering, host allowlist (MIM-71)`

---

### Task 7: SPIKE — cloud attachment mechanism (CONTROLLER-COORDINATED, live)

Not an implementer task. The controller adds a temporary `:live`-tagged diagnostic test (pattern: the 0.3.0 DIAG legs) that, on a real cloud environment ensured with `runtimes: [elixir 1.20]`: (a) probes the skills attachment surface if present on the API, (b) falls back to upload-bootstrap-file + mount as session resource + a system-prompt instruction block, runs a session asking the agent to execute `bash: elixir --version`, and records which mechanism succeeded. One canary dispatch; finding folded back into the spec (§3) by the controller; the temporary test is removed by Task 8's commit. **Success:** `elixir --version` output captured via the built-in bash tool without per-consumer prompt engineering. **Failure of all candidates:** MIM-71 descopes to `bootstrap_script/1` + docs (mechanism (c)), release proceeds — record the decision.

### Task 8: realization wiring (spike-dependent — dispatch ONLY after the controller pins the mechanism in the spec)

**Files:** `lib/req_managed_agents/provisioner/runtimes.ex` + `environments.ex` (+ whatever the pinned mechanism needs), tests per mechanism. The dispatch prompt for this task is written by the controller AFTER Task 7, quoting the spike's finding; the plan pre-commits only the contract: ensured environments with runtimes yield sessions where the runtime is available (or mechanism (c): `ensure_environment` returns `bootstrap: %{script: …, instructions: …}` in the handle and README documents the wiring).

### Task 9: canary discipline + 0.4 legs

**Files:** `test/live/live_smoke_test.exs`

- Migrate the CMA artifacts + provision legs to a **pinned, reused image**: module-attribute env spec, `ensure_environment` with the default ETS store per run (hit-vs-build observed via handle equality across the two legs in one run — same spec must yield the same env id; assert it), sessions remain per-run.
- New leg `:live_env_images`: ensure → tag `canary:current` → resolve → create a session on the resolved image (echo round-trip) → `prune_environments(client, "canary", keep: 2, …)` with tagged protection asserted, cleaning superseded generations from past runs.
- Runtime leg per Task 8's mechanism (or omitted under mechanism (c) — controller decides at dispatch).
- Offline gates as always; live runs only in canary.
- Commit: `test(live): 0.4 canary — pinned images, tag/resolve/prune leg, runtime leg`

### Task 10: docs + CHANGELOG

README: "Environments are images" section (the Docker table, build/tag/run/prune examples, Store.File pinning example); Provisioner/Store/Environments moduledocs already carry their contracts — verify voice; CHANGELOG `## v0.4.0 (unreleased)`: Added (Store behaviour + ETS/File, ensure_environment/tag/resolve/prune, runtimes surface + realization per spike, digest index) / Changed (Provisioner cache keys namespaced — cache-only, no consumer impact). aws-ci-setup.md untouched (no IAM changes). Gates incl. `MIX_ENV=dev mix docs --warnings-as-errors`. Commit: `docs: environments-as-images, stores, runtimes`.

### QA-CHECKPOINT C (closes PR 3) — runtimes + release gate

qa-tester doc: runtimes validation/rendering matrix incl. erlang+elixir OTP-suffix rule and determinism; allowlist merge cases; mechanism-specific offline checks (per spike); full release gate (`format`/`test`/`credo --strict`/`docs`/`dialyzer`/`hex.build` — tarball must ship `lib/req_managed_agents/provisioner/` and `priv/runtime_bootstrap/` — **check `mix.exs` `files:` includes `priv` and ADD IT if absent, it currently does NOT**). Then Task 11.

### Task 11: v0.4.0 stamp + PR 3

`@version "0.4.0"`, CHANGELOG date-stamp, full gate rerun, commit `release: v0.4.0 — environment lifecycle`, bookmark `ryan/mim-71-runtimes-release`, PR 3 (`Closes #36` / `Closes MIM-71`). PAUSE; then canary + tag per the established release flow (controller + user coordination).

---

## Execution notes for the coordinator

- Workspace: continue in `.claude/worktrees/rma-030-artifacts` or a fresh `rma-040` workspace at execution time; spec+plan committed there ride PR 1.
- Sonnet floor for implementers; preflight base-pin in every dispatch; per-task gates include `mix credo --strict` (0.3.0 lessons).
- Task 7 is the only live step before release canaries — one dispatch, findings → spec §3, then Task 8's prompt is authored fresh.
- `priv/` in the package `files:` list is a RELEASE BLOCKER for MIM-71 — QA-C asserts it.
