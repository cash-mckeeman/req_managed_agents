defmodule ReqManagedAgents.ArtifactsTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.{Artifact, Artifacts}

  defmodule EchoStore do
    @behaviour ReqManagedAgents.Artifacts

    @impl true
    def list(store, opts), do: {:ok, [%Artifact{name: "seen", ref: {store, opts}}]}
    @impl true
    def fetch(_store, name, _opts), do: {:ok, "bytes-of-" <> name}
    @impl true
    def put(_store, _name, _contents, _opts), do: :ok
    @impl true
    def delete(_store, "missing", _opts), do: {:error, :not_found}
    def delete(_store, _name, _opts), do: :ok
  end

  test "facade dispatches every verb to the impl with the store" do
    store = {EchoStore, %{tag: :s1}}

    assert {:ok, [%Artifact{name: "seen", ref: {%{tag: :s1}, [scope: :x]}}]} =
             Artifacts.list(store, scope: :x)

    assert {:ok, "bytes-of-report.md"} = Artifacts.fetch(store, "report.md")
    assert :ok = Artifacts.put(store, "in.csv", "a,b")
    assert :ok = Artifacts.delete(store, "report.md")
    assert {:error, :not_found} = Artifacts.delete(store, "missing")
  end

  test "Artifact struct defaults + JSON encoding" do
    a = %Artifact{name: "r.md", size: 12, ref: "file_1"}
    assert %{"name" => "r.md", "size" => 12} = Jason.decode!(Jason.encode!(a))
    assert %Artifact{}.size == nil
  end
end
