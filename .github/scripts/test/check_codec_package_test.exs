ExUnit.start()

defmodule CodecPackageTest do
  use ExUnit.Case, async: true

  @guard Path.expand("../check_package.exs", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "codec-package-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "standalone codec metadata keeps its independent version", %{dir: dir} do
    assert check(dir, "aws_event_stream", "0.2.1", []) == 0
  end

  test "RMA accepts the independent codec Hex range", %{dir: dir} do
    assert check(dir, "req_managed_agents", "0.17.0", [dep("aws_event_stream", "~> 0.1")]) == 0
  end

  for option <- ["path", "git"] do
    test "RMA rejects a #{option} codec dependency in its artifact", %{dir: dir} do
      requirement = [{unquote(option), "local"} | dep("aws_event_stream", "~> 0.1")]
      assert check(dir, "req_managed_agents", "0.17.0", [requirement]) != 0
    end
  end

  test "codec cannot depend on its managed-agent consumers", %{dir: dir} do
    assert check(dir, "aws_event_stream", "0.2.1", [dep("req_managed_agents", "~> 0.2.0")]) != 0
  end

  test "host still requires the RMA family minor", %{dir: dir} do
    assert check(dir, "req_managed_agents_host", "0.17.1", [
             dep("req_managed_agents", "~> 0.16.0")
           ]) != 0

    assert check(dir, "req_managed_agents_host", "0.17.1", [
             dep("req_managed_agents", "~> 0.17.0")
           ]) == 0
  end

  test "license remains required for the independent codec", %{dir: dir} do
    assert check(dir, "aws_event_stream", "0.2.1", [], []) != 0
  end

  defp dep(name, requirement), do: [{"name", name}, {"requirement", requirement}]

  defp check(dir, name, version, requirements, files \\ [{~c"LICENSE", "MIT"}]) do
    inner = Path.join(dir, "contents.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(inner), files, [:compressed])

    metadata =
      Enum.map_join(
        [{"name", name}, {"version", version}, {"requirements", requirements}],
        fn term ->
          IO.iodata_to_binary(:io_lib.format(~c"~tp.~n", [term]))
        end
      )

    tarball = Path.join(dir, "package.tar")

    :ok =
      :erl_tar.create(
        String.to_charlist(tarball),
        [{~c"metadata.config", metadata}, {~c"contents.tar.gz", File.read!(inner)}],
        []
      )

    {_output, status} =
      System.cmd(System.find_executable("elixir"), [@guard, tarball], stderr_to_stdout: true)

    status
  end
end
