defmodule ReqManagedAgents.Acceptance.SourceTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Acceptance.Source

  test "immutable Git checkout attestation rejects changed, added and stale source" do
    root = Path.join(System.tmp_dir!(), "acceptance-source-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    git(root, ["init", "--quiet"])
    hooks = Path.join(root, ".git/acceptance-hooks")
    File.mkdir!(hooks)
    File.write!(Path.join(hooks, "pre-commit"), "#!/bin/sh\nexit 77\n")
    File.chmod!(Path.join(hooks, "pre-commit"), 0o700)
    git(root, ["config", "core.hooksPath", hooks])
    git(root, ["config", "commit.gpgsign", "true"])
    File.mkdir!(Path.join(root, "lib"))
    file = Path.join(root, "lib/example.ex")
    original = "defmodule Example do\nend\n"
    File.write!(file, original)
    git(root, ["add", "lib/example.ex"])

    git(root, [
      "-c",
      "user.name=Acceptance",
      "-c",
      "user.email=acceptance@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "fixture"
    ])

    revision = git(root, ["rev-parse", "HEAD"]) |> String.trim()
    assert {:ok, %{revision: ^revision, root: ^root}} = Source.verify(root, revision)
    File.write!(file, original <> "\n")
    assert {:error, :source_mismatch} = Source.verify(root, revision)
    File.write!(file, original)
    added = Path.join(root, "lib/added.ex")
    File.write!(added, "defmodule Added do\nend\n")
    assert {:error, :source_mismatch} = Source.verify(root, revision)
    File.rm!(added)

    git(root, [
      "-c",
      "user.name=Acceptance",
      "-c",
      "user.email=acceptance@example.invalid",
      "commit",
      "--allow-empty",
      "--quiet",
      "-m",
      "same tree newer identity"
    ])

    assert {:error, :source_mismatch} = Source.verify(root, revision)
  end

  defp git(root, args) do
    {output, 0} =
      System.cmd(
        "git",
        ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-C", root | args],
        stderr_to_stdout: true
      )

    output
  end
end
