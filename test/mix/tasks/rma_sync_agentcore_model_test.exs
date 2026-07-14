defmodule Mix.Tasks.Rma.SyncAgentcoreModelTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Rma.SyncAgentcoreModel, as: Sync

  test "changeset/2 reports added/changed/removed vs a local manifest" do
    fetched = %{"service-2.json" => "AAA", "new.json" => "BBB"}
    local = %{"files" => %{"service-2.json" => sha("OLD"), "gone.json" => sha("X")}}
    cs = Sync.changeset(fetched, local)
    assert "new.json" in cs.added
    assert "service-2.json" in cs.changed
    assert "gone.json" in cs.removed
  end

  test "changeset/2 reports no drift when fetched matches the local manifest exactly" do
    fetched = %{"service-2.json" => "AAA"}
    local = %{"files" => %{"service-2.json" => sha("AAA")}}
    assert Sync.changeset(fetched, local) == %{added: [], changed: [], removed: []}
  end

  test "changeset/2 treats a missing/empty local manifest as everything added" do
    fetched = %{"service-2.json" => "AAA", "other.json" => "BBB"}

    assert Sync.changeset(fetched, %{}) == %{
             added: ["other.json", "service-2.json"],
             changed: [],
             removed: []
           }
  end

  test "manifest_json/2 round-trips through changeset/2 as a no-op" do
    fetched = %{"service-2.json" => "AAA", "sub/other.json" => "BBB"}
    json = Sync.manifest_json(fetched, "deadbeef")
    local = Jason.decode!(json)

    assert local["source"]["repo"] == "boto/botocore"
    assert local["source"]["commit"] == "deadbeef"
    assert Sync.changeset(fetched, local) == %{added: [], changed: [], removed: []}
  end

  defp sha(b), do: :crypto.hash(:sha256, b) |> Base.encode16(case: :lower)
end
