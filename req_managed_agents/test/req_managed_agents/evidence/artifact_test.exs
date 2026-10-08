defmodule ReqManagedAgents.Evidence.ArtifactTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Evidence
  alias ReqManagedAgents.Evidence.{Artifact, Capture, Error}

  setup do
    directory = Path.join(System.tmp_dir!(), "evidence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, capture} =
      Capture.new(%{
        capture_id: "capture",
        provider: :managed,
        session_id: "session",
        started_at: "2026-10-08T12:00:00Z",
        ended_at: "2026-10-08T12:00:00Z"
      })

    %{directory: directory, capture: capture}
  end

  test "published artifact hashes exact bytes and roundtrips the producer", ctx do
    assert {:ok, ref} = Artifact.write(ctx.capture, ctx.directory)
    assert ref.relative_path == "evidence.json"
    bytes = File.read!(Path.join(ctx.directory, ref.relative_path))
    assert ref.sha256 == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert {:ok, decoded} = Evidence.from_wire(Jason.decode!(bytes))
    assert decoded.capture_id == "capture"
    File.write!(Path.join(ctx.directory, ref.relative_path), bytes <> " ")
    refute ref.sha256 == Base.encode16(:crypto.hash(:sha256, bytes <> " "), case: :lower)
    assert {:ok, stat} = File.stat(Path.join(ctx.directory, ref.relative_path))
    assert Bitwise.band(stat.mode, 0o777) == 0o600
  end

  test "refuses overwrite and leaves original artifact intact", ctx do
    path = Path.join(ctx.directory, "evidence.json")
    File.write!(path, "existing")
    assert {:error, %Error{}} = Artifact.write(ctx.capture, ctx.directory)
    assert File.read!(path) == "existing"
    assert File.ls!(ctx.directory) == ["evidence.json"]
  end

  test "rejects symlink targets and symlink directory ancestors", ctx do
    target = Path.join(ctx.directory, "original")
    File.write!(target, "existing")
    File.ln_s!(target, Path.join(ctx.directory, "evidence.json"))
    assert {:error, %Error{}} = Artifact.write(ctx.capture, ctx.directory)
    assert File.read!(target) == "existing"
    real = Path.join(ctx.directory, "real")
    File.mkdir_p!(Path.join(real, "nested"))
    linked = Path.join(ctx.directory, "linked")
    File.ln_s!(real, linked)
    assert {:error, %Error{}} = Artifact.write(ctx.capture, Path.join(linked, "nested"))
    refute File.exists?(Path.join(real, "nested/evidence.json"))
  end

  test "concurrent writers publish exactly one complete artifact", ctx do
    results =
      1..6
      |> Task.async_stream(fn _ -> Artifact.write(ctx.capture, ctx.directory) end)
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert File.ls!(ctx.directory) == ["evidence.json"]

    assert {:ok, _} =
             ctx.directory
             |> Path.join("evidence.json")
             |> File.read!()
             |> Jason.decode!()
             |> Evidence.from_wire()
  end

  test "reference constructor rejects traversal and malformed digests" do
    assert {:error, %Error{}} =
             Artifact.Ref.new(%{relative_path: "../evidence.json", sha256: "bad"})

    assert {:error, %Error{}} = Artifact.Ref.new(%{relative_path: "evidence.json", sha256: "bad"})
  end

  test "artifact publication preserves explicit collection limits", ctx do
    source = %{
      id: "source",
      kind: :claude_session,
      scope: "session",
      status: :complete,
      pages: 101
    }

    assert {:ok, capture} = Capture.new(%{ctx.capture | sources: [source]}, max_pages: 102)
    assert {:ok, ref} = Artifact.write(capture, ctx.directory)
    wire = ctx.directory |> Path.join(ref.relative_path) |> File.read!() |> Jason.decode!()
    assert hd(wire["sources"])["status"] == "complete"
    assert wire["diagnostics"] == []
  end
end
