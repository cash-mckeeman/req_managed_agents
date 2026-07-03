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
end
