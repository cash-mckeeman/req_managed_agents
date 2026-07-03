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
end
