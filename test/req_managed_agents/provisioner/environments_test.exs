defmodule ReqManagedAgents.Provisioner.EnvironmentsTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Provisioner
  alias ReqManagedAgents.Provisioner.Store

  @spec1 %{type: :cloud, packages: %{pip: ["pandas"]}, networking: %{type: :unrestricted}}
  @spec2 %{
    type: :cloud,
    packages: %{pip: ["pandas", "numpy"]},
    networking: %{type: :unrestricted}
  }

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
               name: "d",
               store: fresh_store(),
               create_fun: create_fun,
               list_fun: list_fun
             )
  end

  test "archived exact digest-name in recovery surfaces environment_archived" do
    digest_name_holder = :ets.new(:t, [:public])

    create_fun = fn body ->
      :ets.insert(digest_name_holder, {:name, body.name})
      {:error, {:http_error, 409, %{}}}
    end

    list_fun = fn ->
      [{:name, name}] = :ets.lookup(digest_name_holder, :name)

      {:ok,
       %{
         "data" => [
           %{"id" => "env_old", "name" => name, "archived_at" => "2026-01-01T00:00:00Z"}
         ]
       }}
    end

    # 409 + only-archived match -> retry create once more? NO — per design the
    # 409 name IS the digest name; if list shows only archived matches, surface
    # a clear error (the operator archived this exact image; re-creating with
    # the same name will keep 409ing on some providers). Expect:
    assert {:error, {:environment_archived, _name}} =
             Provisioner.ensure_environment(:c, @spec1,
               name: "d",
               store: fresh_store(),
               create_fun: create_fun,
               list_fun: list_fun
             )
  end

  test "409 with no name match at all is a name conflict, not archived" do
    create_fun = fn _body -> {:error, {:http_error, 409, %{}}} end

    list_fun = fn ->
      {:ok,
       %{"data" => [%{"id" => "env_x", "name" => "unrelated_deadbeef", "archived_at" => nil}]}}
    end

    assert {:error, {:environment_name_conflict, _name}} =
             Provisioner.ensure_environment(:c, @spec1,
               name: "d",
               store: fresh_store(),
               create_fun: create_fun,
               list_fun: list_fun
             )
  end

  @tag :capture_log
  test "malformed store entry is treated as a miss: rebuild and overwrite" do
    {smod, sopts} = store = fresh_store()
    key = "provision:env:" <> Provisioner.hash({"d", @spec1})

    # Pre-seed a malformed entry directly (foreign/corrupt store content).
    :ok = smod.put(sopts, key, %{"environment_id" => "x"})

    create_fun = fn body -> {:ok, %{"id" => "env_fresh", "name" => body.name}} end

    assert {:ok, %{environment_id: "env_fresh", name: name, digest: digest}} =
             Provisioner.ensure_environment(:c, @spec1,
               name: "d",
               store: store,
               create_fun: create_fun
             )

    # The malformed entry was overwritten with the full handle.
    assert {:ok, %{environment_id: "env_fresh", name: ^name, digest: ^digest}} =
             smod.get(sopts, key)
  end

  test "provider errors pass through" do
    assert {:error, {:http_error, 500, _}} =
             Provisioner.ensure_environment(:c, @spec1,
               name: "d",
               store: fresh_store(),
               create_fun: fn _ -> {:error, {:http_error, 500, %{}}} end
             )
  end

  describe "tags" do
    test "tag + resolve round-trip via the registry entry" do
      store = fresh_store()
      # Use body.name as ID so spec1 and spec2 produce distinct environment_ids
      # (their digest-names differ: base <> "_" <> digest8).
      create_fun = fn body -> {:ok, %{"id" => body.name, "name" => body.name}} end

      {:ok, %{digest: digest} = handle} =
        Provisioner.ensure_environment(:c, @spec1,
          name: "d",
          store: store,
          create_fun: create_fun
        )

      assert :ok = Provisioner.tag("d", "prod", handle, store: store)
      assert {:ok, resolved} = Provisioner.resolve("d:prod", store: store)
      assert resolved.environment_id == handle.environment_id

      # Retag to another digest moves the pointer.
      {:ok, h2} =
        Provisioner.ensure_environment(:c, @spec2,
          name: "d",
          store: store,
          create_fun: create_fun
        )

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
        Provisioner.ensure_environment(:c, @spec1,
          name: "d",
          store: store,
          create_fun: create_fun
        )

      :ok = Provisioner.tag("d", "prod", handle, store: store)
      # Simulate a pruned/evicted provision entry with a surviving tag.
      :ok = mod.delete_value(sopts, handle)

      assert {:error, {:untracked_digest, _}} = Provisioner.resolve("d:prod", store: store)
    end

    test "resolve raises ArgumentError on a ref without a colon" do
      store = fresh_store()

      assert_raise ArgumentError, ~r/base:tag/, fn ->
        Provisioner.resolve("nocolon", store: store)
      end
    end

    test "tag accepts a raw digest string too" do
      store = fresh_store()
      assert :ok = Provisioner.tag("d", "prod", "abcd1234", store: store)
      # No provision entry for it -> untracked on resolve.
      assert {:error, {:untracked_digest, "abcd1234"}} =
               Provisioner.resolve("d:prod", store: store)
    end
  end

  describe "prune" do
    defp env(name, created_at, archived \\ nil),
      do: %{
        "id" => "id_" <> name,
        "name" => name,
        "created_at" => created_at,
        "archived_at" => archived
      }

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

      archive_fun = fn id ->
        send(test_pid, {:archived, id})
        {:ok, %{"id" => id}}
      end

      list_fun = fn -> {:ok, %{"data" => envs}} end

      assert {:error, :keep_required} =
               Provisioner.prune_environments(:c, "d", store: store, list_fun: list_fun)

      assert {:error, :keep_required} =
               Provisioner.prune_environments(:c, "d", keep: 0, store: store, list_fun: list_fun)

      assert {:error, :keep_required} =
               Provisioner.prune_environments(:c, "d", keep: -1, store: store, list_fun: list_fun)

      assert {:ok, %{archived: archived, kept: kept}} =
               Provisioner.prune_environments(:c, "d",
                 keep: 1,
                 store: store,
                 list_fun: list_fun,
                 archive_fun: archive_fun
               )

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

      {smod, sopts} = store
      # Seed digest-index entries so we can prove store cleanup stops at the failure.
      :ok = smod.put(sopts, "digest:d:11111111", %{"environment_id" => "id_d_11111111"})
      :ok = smod.put(sopts, "digest:d:22222222", %{"environment_id" => "id_d_22222222"})

      assert {:error, {:partial, ["d_11111111"], {"d_22222222", {:http_error, 500, %{}}}}} =
               Provisioner.prune_environments(:c, "d",
                 keep: 1,
                 store: store,
                 list_fun: fn -> {:ok, %{"data" => envs}} end,
                 archive_fun: archive_fun
               )

      # The archived env's index entry is cleaned; the FAILED env's survives.
      assert :miss = smod.get(sopts, "digest:d:11111111")
      assert {:ok, _} = smod.get(sopts, "digest:d:22222222")
    end

    test "a malformed atom-keyed store entry (missing digest) is rebuilt, not returned" do
      {smod, sopts} = store = fresh_store()
      key = "provision:env:" <> ReqManagedAgents.Provisioner.hash({"d", @spec1})
      :ok = smod.put(sopts, key, %{environment_id: "env_partial"})

      create_fun = fn body -> {:ok, %{"id" => "env_rebuilt", "name" => body.name}} end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{environment_id: "env_rebuilt", digest: _}} =
                   Provisioner.ensure_environment(:c, @spec1,
                     name: "d",
                     store: store,
                     create_fun: create_fun
                   )
        end)

      assert log =~ "unexpected shape"
      # Entry healed with the full shape.
      assert {:ok, %{environment_id: "env_rebuilt"}} =
               Provisioner.ensure_environment(:c, @spec1,
                 name: "d",
                 store: store,
                 create_fun: fn _ -> flunk("must not re-create after heal") end
               )
    end

    test "a longer base sharing the name prefix is never a candidate" do
      store = fresh_store()
      test_pid = self()

      envs = [
        env("data_aaaaaaaa", "2026-07-01T00:00:00Z"),
        env("data_bbbbbbbb", "2026-07-02T00:00:00Z"),
        env("data_analysis_abc12345", "2026-07-03T00:00:00Z")
      ]

      archive_fun = fn id ->
        send(test_pid, {:archived, id})
        {:ok, %{}}
      end

      assert {:ok, %{archived: archived, kept: kept}} =
               Provisioner.prune_environments(:c, "data",
                 keep: 1,
                 store: store,
                 list_fun: fn -> {:ok, %{"data" => envs}} end,
                 archive_fun: archive_fun
               )

      refute "data_analysis_abc12345" in archived
      refute "data_analysis_abc12345" in kept
      assert kept == ["data_bbbbbbbb"]
      assert archived == ["data_aaaaaaaa"]
      refute_received {:archived, "id_data_analysis_abc12345"}
    end

    test "a name with a repeated base prefix is not a version and is untouched" do
      store = fresh_store()
      test_pid = self()

      envs = [
        env("d_d_aaaaaaaa", "2026-07-05T00:00:00Z"),
        env("d_bbbbbbbb", "2026-07-02T00:00:00Z"),
        env("d_cccccccc", "2026-07-03T00:00:00Z")
      ]

      archive_fun = fn id ->
        send(test_pid, {:archived, id})
        {:ok, %{}}
      end

      assert {:ok, %{archived: archived, kept: kept}} =
               Provisioner.prune_environments(:c, "d",
                 keep: 1,
                 store: store,
                 list_fun: fn -> {:ok, %{"data" => envs}} end,
                 archive_fun: archive_fun
               )

      refute "d_d_aaaaaaaa" in archived
      refute "d_d_aaaaaaaa" in kept
      assert kept == ["d_cccccccc"]
      assert archived == ["d_bbbbbbbb"]
      refute_received {:archived, "id_d_d_aaaaaaaa"}
    end
  end

  describe "bootstrap on the returned handle (derived, never stored)" do
    alias ReqManagedAgents.Provisioner.Runtimes

    @runtimes [
      %{lang: :erlang, version: "29.0.2", via: :mise},
      %{lang: :elixir, version: "1.20.2", via: :mise}
    ]
    @rt_spec %{type: :cloud, runtimes: @runtimes, networking: %{type: :unrestricted}}

    defmodule PutSpyStore do
      @moduledoc false
      # :miss on every get; records each put VALUE so tests can assert the
      # stored shape. Store opts = test pid.
      @behaviour Store

      @impl true
      def get(_pid, _key), do: :miss

      @impl true
      def put(pid, key, value) do
        send(pid, {:put, key, value})
        :ok
      end

      @impl true
      def delete(_pid, _key), do: :ok

      @impl true
      def delete_value(_pid, _value), do: :ok
    end

    test "fresh create returns bootstrap with script + instructions" do
      create_fun = fn body -> {:ok, %{"id" => "env_1", "name" => body.name}} end

      assert {:ok, %{bootstrap: %{script: script, instructions: instructions}}} =
               Provisioner.ensure_environment(:c, @rt_spec,
                 name: "d",
                 store: fresh_store(),
                 create_fun: create_fun
               )

      assert script == Runtimes.bootstrap_script(@runtimes)
      assert instructions == Runtimes.system_prompt_block(@runtimes)
    end

    test "store HIT still returns bootstrap (no create, no list)" do
      store = fresh_store()
      create_fun = fn body -> {:ok, %{"id" => "env_1", "name" => body.name}} end

      {:ok, _} =
        Provisioner.ensure_environment(:c, @rt_spec,
          name: "d",
          store: store,
          create_fun: create_fun
        )

      assert {:ok, %{bootstrap: %{script: script, instructions: instructions}}} =
               Provisioner.ensure_environment(:c, @rt_spec,
                 name: "d",
                 store: store,
                 create_fun: fn _ -> flunk("must not create on hit") end,
                 list_fun: fn -> flunk("must not list on hit") end
               )

      assert script == Runtimes.bootstrap_script(@runtimes)
      assert instructions == Runtimes.system_prompt_block(@runtimes)
    end

    test "recovery path (409 -> list) carries bootstrap" do
      create_fun = fn _body -> {:error, {:http_error, 409, %{}}} end
      digest = @rt_spec |> Provisioner.hash() |> binary_part(0, 8) |> String.downcase()
      name = "d_" <> digest

      list_fun = fn ->
        {:ok, %{"data" => [%{"id" => "env_recovered", "name" => name, "archived_at" => nil}]}}
      end

      assert {:ok, %{environment_id: "env_recovered", bootstrap: %{script: _, instructions: _}}} =
               Provisioner.ensure_environment(:c, @rt_spec,
                 name: "d",
                 store: fresh_store(),
                 create_fun: create_fun,
                 list_fun: list_fun
               )
    end

    test "stored values never carry bootstrap (spy on every put)" do
      create_fun = fn body -> {:ok, %{"id" => "env_1", "name" => body.name}} end

      assert {:ok, %{bootstrap: %{}}} =
               Provisioner.ensure_environment(:c, @rt_spec,
                 name: "d",
                 store: {PutSpyStore, self()},
                 create_fun: create_fun
               )

      # Two writes: the provision entry and the digest index — both 3-field.
      assert_received {:put, "provision:env:" <> _, provision_value}
      assert_received {:put, "digest:d:" <> _, digest_value}

      for value <- [provision_value, digest_value] do
        refute Map.has_key?(value, :bootstrap)
        assert Map.keys(value) |> Enum.sort() == [:digest, :environment_id, :name]
      end
    end

    test "spec without runtimes yields no :bootstrap key" do
      create_fun = fn body -> {:ok, %{"id" => "env_1", "name" => body.name}} end

      assert {:ok, handle} =
               Provisioner.ensure_environment(:c, @spec1,
                 name: "d",
                 store: fresh_store(),
                 create_fun: create_fun
               )

      refute Map.has_key?(handle, :bootstrap)
    end
  end

  test "wire config never carries :runtimes — library vocabulary, provider-opaque" do
    test_pid = self()

    create_fun = fn body ->
      send(test_pid, {:wire_body, body})
      {:ok, %{"id" => "env_rt", "name" => body.name}}
    end

    spec =
      Map.put(@spec1, :runtimes, [%{lang: :elixir, version: "1.20.2", via: :mise}])

    {:ok, %{bootstrap: %{script: _}}} =
      Provisioner.ensure_environment(:c, spec,
        name: "d",
        store: fresh_store(),
        create_fun: create_fun
      )

    assert_received {:wire_body, %{config: config}}
    refute Map.has_key?(config, :runtimes)
  end
end
