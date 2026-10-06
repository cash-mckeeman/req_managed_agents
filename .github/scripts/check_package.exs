# Usage: elixir check_package.exs <tarball built by `mix hex.build`>
#
# Asserts what `mix hex.build` exiting 0 cannot: the tarball ships LICENSE,
# and every requirement on a sibling package names the family minor
# (~> X.Y.Z with X.Y this package's own minor) from Hex, never a path or git.
defmodule CheckPackage do
  @siblings ~w(req_managed_agents req_managed_agents_host)

  def main([tarball]) do
    {:ok, outer} = :erl_tar.extract(String.to_charlist(tarball), [:memory])
    outer = Map.new(outer, fn {name, bin} -> {List.to_string(name), bin} end)
    meta = metadata(Map.fetch!(outer, "metadata.config"))

    {:ok, inner} =
      :erl_tar.extract({:binary, Map.fetch!(outer, "contents.tar.gz")}, [:memory, :compressed])

    files = Enum.map(inner, fn {name, _} -> List.to_string(name) end)
    app = meta["name"]
    version = Version.parse!(meta["version"])

    requirements = requirements(meta)

    missing_sibling =
      if app == "req_managed_agents_host" and
           not Enum.any?(requirements, fn {name, _} -> name == "req_managed_agents" end),
         do: ["req_managed_agents requirement is missing"],
         else: []

    failures =
      missing_sibling ++
        license_failures(files) ++
        Enum.flat_map(requirements, &sibling_failures(&1, app, version))

    case failures do
      [] ->
        IO.puts(
          "check_package: #{app} #{version}: LICENSE shipped; sibling requirements at the family minor"
        )

      _ ->
        Enum.each(failures, &IO.puts(:stderr, "check_package: #{app}: " <> &1))
        System.halt(1)
    end
  end

  defp license_failures(files) do
    if "LICENSE" in files,
      do: [],
      else: ["LICENSE is not in the tarball (add it to package files:)"]
  end

  defp sibling_failures({name, req}, app, %Version{major: major, minor: minor}) do
    cond do
      name not in @siblings or name == app ->
        []

      Map.has_key?(req, "path") or Map.has_key?(req, "git") ->
        ["#{name} is a path or git dependency"]

      not family_minor?(req["requirement"], major, minor) ->
        ["#{name} requirement #{inspect(req["requirement"])} is not ~> #{major}.#{minor}.Z"]

      true ->
        []
    end
  end

  defp family_minor?(requirement, major, minor) do
    case Regex.run(~r/^~> (\d+)\.(\d+)\.(\d+)$/, requirement || "") do
      [_, ma, mi, _] -> {String.to_integer(ma), String.to_integer(mi)} == {major, minor}
      _ -> false
    end
  end

  defp requirements(meta) do
    for r <- Map.get(meta, "requirements", []) do
      case r do
        {name, kv} when is_binary(name) -> {name, Map.new(kv)}
        kv when is_list(kv) -> {Map.new(kv)["name"], Map.new(kv)}
      end
    end
  end

  defp metadata(bin) do
    path =
      Path.join(
        System.tmp_dir!(),
        "check_package_metadata_#{System.unique_integer([:positive])}.config"
      )

    File.write!(path, bin)

    try do
      {:ok, terms} = :file.consult(String.to_charlist(path))
      Map.new(terms)
    after
      File.rm!(path)
    end
  end
end

CheckPackage.main(System.argv())
