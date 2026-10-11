defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.BearerCredentialTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.BearerCredential

  setup do
    dir = Path.join(System.tmp_dir!(), "bearer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: Path.join(dir, "credential.json")}
  end

  test "parses a usable credential and redacts its token", %{path: path} do
    File.write!(path, ~s({"access_token":"synthetic-secret","expires_at":1031}))
    assert {:ok, credential} = BearerCredential.read(path, 1000)
    assert credential.expires_at == 1031
    refute inspect(credential) =~ "synthetic-secret"
  end

  test "reads the credential produced by the renewal executor" do
    path = Path.expand("../../../fixtures/anthropic_bearer.json", __DIR__)
    assert {:ok, credential} = BearerCredential.read(path, 2_000_000_000)
    assert credential.access_token == "synthetic-producer-token"
    assert credential.expires_at == 2_000_000_600
  end

  test "rejects malformed credentials and the mandatory expiry boundary", %{path: path} do
    for {body, reason} <- [
          {"{", :invalid_file},
          {"[]", :invalid_file},
          {~s({"access_token":"","expires_at":1100}), :invalid_token},
          {~s({"access_token":"   ","expires_at":1100}), :invalid_token},
          {Jason.encode!(%{access_token: "token\r\ninjected", expires_at: 1100}), :invalid_token},
          {~s({"access_token":"token","expires_at":"1100"}), :invalid_expiry},
          {~s({"access_token":"token","expires_at":1100.5}), :invalid_expiry},
          {~s({"access_token":"token","expires_at":1030}), :expired},
          {~s({"access_token":"token","expires_at":999}), :expired},
          {String.duplicate("x", 65_537), :invalid_file}
        ] do
      File.write!(path, body)
      assert {:error, ^reason} = BearerCredential.read(path, 1000)
    end
  end

  test "refuses missing files, directories and symlinks", %{path: path} do
    assert {:error, :unreadable} = BearerCredential.read(path, 1000)
    assert {:error, :invalid_file} = BearerCredential.read(Path.dirname(path), 1000)
    target = path <> ".target"
    File.write!(target, ~s({"access_token":"token","expires_at":1100}))
    File.ln_s!(target, path)
    assert {:error, :invalid_file} = BearerCredential.read(path, 1000)
  end
end
