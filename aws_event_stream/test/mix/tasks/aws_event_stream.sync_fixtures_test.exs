defmodule Mix.Tasks.AwsEventStream.SyncFixturesTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.AwsEventStream.SyncFixtures

  @sha "aabbccddeeff00112233445566778899aabbccdd"

  setup do
    dir = Path.join(System.tmp_dir!(), "sync_fixtures_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp seed(dir, files) do
    for {path, bin} <- files do
      dest = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, bin)
    end
  end

  describe "changeset/2" do
    test "a missing local dir means everything is added", %{dir: dir} do
      fetched = %{"encoded/positive/a" => "1", "decoded/positive/a" => "2"}

      assert SyncFixtures.changeset(fetched, dir) == %{
               added: ["decoded/positive/a", "encoded/positive/a"],
               changed: [],
               removed: []
             }
    end

    test "detects changed and removed files, ignores identical ones", %{dir: dir} do
      seed(dir, %{
        "encoded/positive/same" => "x",
        "encoded/positive/old" => "1",
        "encoded/negative/gone" => "z"
      })

      fetched = %{
        "encoded/positive/same" => "x",
        "encoded/positive/old" => "2",
        "encoded/positive/new" => "n"
      }

      assert SyncFixtures.changeset(fetched, dir) == %{
               added: ["encoded/positive/new"],
               changed: ["encoded/positive/old"],
               removed: ["encoded/negative/gone"]
             }
    end

    test "manifest.json is never part of the changeset", %{dir: dir} do
      seed(dir, %{"manifest.json" => "{}", "encoded/positive/a" => "1"})
      fetched = %{"encoded/positive/a" => "1"}
      assert SyncFixtures.changeset(fetched, dir) == %{added: [], changed: [], removed: []}
    end

    test "dot-prefixed local files are seen (no permanent-drift loop)", %{dir: dir} do
      seed(dir, %{".hidden" => "x"})
      fetched = %{".hidden" => "x"}
      assert SyncFixtures.changeset(fetched, dir) == %{added: [], changed: [], removed: []}
    end
  end

  describe "apply_sync/4 + manifest" do
    test "writes added/changed, removes removed, and pins the manifest", %{dir: dir} do
      seed(dir, %{"encoded/positive/old" => "1", "encoded/negative/gone" => "z"})
      fetched = %{"encoded/positive/old" => "2", "encoded/positive/new" => "n"}
      cs = SyncFixtures.changeset(fetched, dir)

      assert :ok = SyncFixtures.apply_sync(fetched, cs, @sha, dir)

      assert File.read!(Path.join(dir, "encoded/positive/old")) == "2"
      assert File.read!(Path.join(dir, "encoded/positive/new")) == "n"
      refute File.exists?(Path.join(dir, "encoded/negative/gone"))

      manifest = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
      assert manifest["source"]["repo"] == "aws/aws-sdk-go-v2"
      assert manifest["source"]["path"] == "aws/protocol/eventstream/testdata"
      assert manifest["source"]["commit"] == @sha

      assert manifest["files"]["encoded/positive/new"] ==
               Base.encode16(:crypto.hash(:sha256, "n"), case: :lower)

      assert Map.keys(manifest["files"]) |> Enum.sort() == [
               "encoded/positive/new",
               "encoded/positive/old"
             ]

      # a re-run against the applied state is a no-op
      assert SyncFixtures.changeset(fetched, dir) == %{added: [], changed: [], removed: []}
      assert SyncFixtures.local_manifest_commit(dir) == @sha
    end

    test "manifest_json is deterministic and newline-terminated" do
      # zzz- prefix keeps the keys from colliding with source-block text when
      # asserting serialization order below
      fetched = %{"zzz-b" => "2", "zzz-a" => "1"}
      json = SyncFixtures.manifest_json(fetched, @sha)
      assert json == SyncFixtures.manifest_json(fetched, @sha)
      assert String.ends_with?(json, "\n")
      # sorted file keys: zzz-a serialized before zzz-b
      assert :binary.match(json, ~s("zzz-a")) < :binary.match(json, ~s("zzz-b"))
    end
  end

  test "local_manifest_commit is nil when absent or unparseable", %{dir: dir} do
    assert SyncFixtures.local_manifest_commit(dir) == nil
    seed(dir, %{"manifest.json" => "not json"})
    assert SyncFixtures.local_manifest_commit(dir) == nil
  end

  test "summary names every file and both shas" do
    cs = %{
      added: ["encoded/positive/new"],
      changed: ["decoded/positive/old"],
      removed: ["encoded/negative/gone"]
    }

    s = SyncFixtures.summary(cs, "1111111111111111", "2222222222222222")
    assert s =~ "111111111111 -> 222222222222"
    assert s =~ "added:   encoded/positive/new"
    assert s =~ "changed: decoded/positive/old"
    assert s =~ "removed: encoded/negative/gone"
    assert s =~ "https://github.com/aws/aws-sdk-go-v2/compare/1111111111111111...2222222222222222"
    # first sync has no prior sha and no compare link
    first = SyncFixtures.summary(cs, nil, "2222222222222222")
    assert first =~ "(none) -> 222222222222"
    refute first =~ "/compare/"
  end
end
