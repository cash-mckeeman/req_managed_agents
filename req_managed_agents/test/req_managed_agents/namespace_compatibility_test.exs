defmodule ReqManagedAgents.NamespaceCompatibilityTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Client, as: Legacy
  alias ReqManagedAgents.Providers.ClaudeManagedAgents
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.{Artifacts, Client, Stream}

  defmodule OldBehaviourClient do
    @behaviour ReqManagedAgents.Client.Behaviour
    for {name, arity} <- ReqManagedAgents.Client.Behaviour.behaviour_info(:callbacks) do
      args = Macro.generate_arguments(arity, __MODULE__)
      @impl true
      def unquote(name)(unquote_splicing(args)) do
        [client | rest] = [unquote_splicing(args)]
        %ReqManagedAgents.Client{} = client
        send(self(), {:legacy_callback, unquote(name), client, rest})
        {:error, :injected_failure}
      end
    end
  end

  test "canonical and legacy clients retain transport options and redact secrets" do
    stub = fn conn ->
      assert conn.request_path == "/v1/agents/a1"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["sk-private-redaction-fixture"]
      Req.Test.json(conn, %{id: "a1"})
    end

    for mod <- [Client, Legacy] do
      client =
        mod.new(
          api_key: "sk-private-redaction-fixture",
          receive_timeout: 321,
          profile: :custom,
          req_options: [plug: stub, retry: false]
        )

      assert client.__struct__ == mod
      refute inspect(client) =~ "sk-private-redaction-fixture"
      assert {:ok, %{"id" => "a1"}} = Client.get_agent(client, "a1")
      assert {:ok, %{"id" => "a1"}} = Legacy.get_agent(client, "a1")
      assert client.receive_timeout == 321
      assert client.profile == :custom
    end

    assert %Legacy{} = ReqManagedAgents.new(api_key: "sk-private-redaction-fixture")
  end

  test "canonical stream accepts both client structs and preserves message tags" do
    for mod <- [Client, Legacy] do
      client =
        mod.new(
          api_key: "sk-private-redaction-fixture",
          req_options: [
            adapter: fn request ->
              {request,
               %Req.Response{
                 status: 403,
                 body: %Req.Response.Async{ref: make_ref(), cancel_fun: fn _ -> :ok end}
               }}
            end
          ]
        )

      ref = make_ref()

      for stream <- [Stream, ReqManagedAgents.Stream] do
        assert :ok = stream.stream(client, "s1", self(), ref: ref)
        assert_receive {:managed_agents, ^ref, {:error, {:status, 403}}}
      end
    end
  end

  test "artifact injection invokes old behaviour with original client and preserves errors" do
    client = Legacy.new(api_key: "sk-private-redaction-fixture")

    for mod <- [Artifacts, ReqManagedAgents.Artifacts.ClaudeFiles] do
      store = mod.store(client, "s1", client_mod: OldBehaviourClient)
      assert store.client === client
      assert store.client_mod == OldBehaviourClient
      assert {:error, :injected_failure} = mod.list(store)
      assert_receive {:legacy_callback, :list_files, ^client, [[params: %{scope_id: "s1"}]]}
      assert {:error, :injected_failure} = mod.put(store, "a.txt", "contents")
      assert_receive {:legacy_callback, :upload_file, ^client, [%{file: {"a.txt", "contents"}}]}
    end
  end

  test "provider resume preserves injected client identity" do
    client = Legacy.new(api_key: "sk-private-redaction-fixture")

    assert {:ok, %{client: ^client}} =
             ClaudeManagedAgents.open(
               [client: client, session_id: "s1"],
               self()
             )
  end
end
