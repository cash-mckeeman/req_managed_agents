defmodule ReqManagedAgents.Artifacts.ClaudeFilesTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.{Artifact, Artifacts}
  alias ReqManagedAgents.Artifacts.ClaudeFiles

  # Stub of the Client.Behaviour surface ClaudeFiles touches. Sends every call
  # to the test pid so interactions are assertable.
  defmodule StubClient do
    def list_files(_c, opts) do
      send(self_pid(), {:list_files, opts})

      {:ok,
       %{
         "data" => [
           %{
             "id" => "file_old",
             "filename" => "report.md",
             "size_bytes" => 10,
             "created_at" => "2026-07-01T00:00:00Z"
           },
           %{
             "id" => "file_new",
             "filename" => "report.md",
             "size_bytes" => 20,
             "created_at" => "2026-07-03T00:00:00Z"
           },
           %{
             "id" => "file_z",
             "filename" => "data.csv",
             "size_bytes" => 5,
             "created_at" => "2026-07-02T00:00:00Z"
           }
         ]
       }}
    end

    def download_file(_c, id) do
      send(self_pid(), {:download, id})
      {:ok, "bytes:" <> id}
    end

    def delete_file(_c, id) do
      send(self_pid(), {:delete, id})
      {:ok, %{"deleted" => true}}
    end

    def upload_file(_c, params) do
      send(self_pid(), {:upload, params})
      {:ok, %{"id" => "file_up"}}
    end

    def attach_file_to_session(_c, sid, params) do
      send(self_pid(), {:attach, sid, params})
      {:ok, %{"id" => "res_1"}}
    end

    defp self_pid, do: Process.get(:test_pid) || self()
  end

  setup do
    Process.put(:test_pid, self())
    store = {ClaudeFiles, ClaudeFiles.store(:fake_client, "sess_1", client_mod: StubClient)}
    {:ok, store: store}
  end

  test "list scopes by session and maps to Artifact structs", %{store: store} do
    assert {:ok, artifacts} = Artifacts.list(store)
    assert_received {:list_files, opts}
    assert opts[:params] == %{scope_id: "sess_1"}

    assert [%Artifact{name: "report.md", ref: "file_old", size: 10} | _] = artifacts
    assert length(artifacts) == 3
  end

  test "fetch downloads the NEWEST match by created_at", %{store: store} do
    assert {:ok, "bytes:file_new"} = Artifacts.fetch(store, "report.md")
    assert_received {:download, "file_new"}
  end

  test "fetch of a missing name is :not_found", %{store: store} do
    assert {:error, :not_found} = Artifacts.fetch(store, "nope.txt")
  end

  test "delete removes the newest match", %{store: store} do
    assert :ok = Artifacts.delete(store, "report.md")
    assert_received {:delete, "file_new"}
  end

  test "put uploads then attaches at the default mount path", %{store: store} do
    assert :ok = Artifacts.put(store, "in.csv", "a,b")
    assert_received {:upload, %{purpose: "agent", file: {"in.csv", "a,b"}}}
    assert_received {:attach, "sess_1", %{file_id: "file_up", mount_path: "/data/in.csv"}}
  end

  test "put honors a custom mount_path", %{store: store} do
    assert :ok = Artifacts.put(store, "in.csv", "a,b", mount_path: "/inputs/in.csv")
    assert_received {:attach, _, %{mount_path: "/inputs/in.csv"}}
  end

  # A list body without a "data" key must not leak through as a bare {:ok, body}.
  defmodule NoDataStubClient do
    def list_files(_c, _opts), do: {:ok, %{}}
  end

  describe "unexpected list bodies" do
    setup do
      store =
        {ClaudeFiles, ClaudeFiles.store(:fake_client, "sess_1", client_mod: NoDataStubClient)}

      {:ok, store: store}
    end

    test "list normalizes a body without \"data\" to an error", %{store: store} do
      assert {:error, {:unexpected_response, %{}}} = Artifacts.list(store)
    end

    test "fetch normalizes a body without \"data\" to an error (via newest/3)", %{store: store} do
      assert {:error, {:unexpected_response, %{}}} = Artifacts.fetch(store, "report.md")
    end
  end

  describe "the outputs-dir convention constant" do
    test "outputs_dir/0 is the single source of truth for the sandbox outputs path" do
      assert ClaudeFiles.outputs_dir() == "/mnt/session/outputs"
    end

    test "output_path/1 builds the absolute deliverable path" do
      assert ClaudeFiles.output_path("report.md") == "/mnt/session/outputs/report.md"
    end
  end
end
