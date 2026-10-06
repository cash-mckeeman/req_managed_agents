# Usage: elixir check_package.exs <tarball built by `mix hex.build`>
#
# Asserts what `mix hex.build` exiting 0 cannot: the tarball ships LICENSE,
# and every requirement on a sibling package names the family minor
# (~> X.Y.Z with X.Y this package's own minor) from Hex, never a path or git.
defmodule CheckPackage do
  @siblings ~w(req_managed_agents req_managed_agents_host)

  def main([tarball]) do
    outer =
      tarball
      |> String.to_charlist()
      |> extract("tarball #{tarball}", [:memory])
      |> Map.new(fn {name, bin} -> {List.to_string(name), bin} end)

    meta = metadata(Map.fetch!(outer, "metadata.config"))

    inner =
      extract({:binary, Map.fetch!(outer, "contents.tar.gz")}, "contents.tar.gz in #{tarball}", [
        :memory,
        :compressed
      ])

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
        license_failures(inner) ++
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

  defp extract(source, what, opts) do
    case :erl_tar.extract(source, opts) do
      {:ok, files} -> files
      {:error, reason} -> fail("cannot read #{what}: #{inspect(reason)}")
    end
  end

  defp fail(message) do
    IO.puts(:stderr, "check_package: " <> message)
    System.halt(1)
  end

  defp license_failures(inner) do
    case Enum.find(inner, fn {name, _} -> List.to_string(name) == "LICENSE" end) do
      nil -> ["LICENSE is not in the tarball (add it to package files:)"]
      {_, bin} when byte_size(bin) == 0 -> ["LICENSE in the tarball is empty"]
      {_, _} -> []
    end
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

    consulted =
      try do
        :file.consult(String.to_charlist(path))
      after
        File.rm!(path)
      end

    case consulted do
      {:ok, terms} -> Map.new(terms)
      {:error, reason} -> fail("cannot read metadata.config: #{inspect(reason)}")
    end
  end
end

CheckPackage.main(System.argv())
