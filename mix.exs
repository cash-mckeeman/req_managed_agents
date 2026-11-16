defmodule ReqManagedAgentsRoot.MixProject do
  use Mix.Project

  # Publish order. A package is published only while it is listed here.
  @family ~w(req_managed_agents req_managed_agents_host)
  @publish ["aws_event_stream" | @family]

  def project do
    [app: :req_managed_agents_root, version: "0.0.0", aliases: aliases()]
  end

  defp aliases do
    [
      # The root has no tests. Without this, `mix test --only live` here
      # exits 0 having run nothing, so a step that forgot its working
      # directory would pass.
      test: &refuse_root_test/1,
      publish_order: &publish_order/1,
      release_packages: &release_packages/1,
      package_version: &package_version/1
    ]
  end

  defp refuse_root_test(_args) do
    Mix.raise("run mix test from aws_event_stream/, req_managed_agents/ or req_managed_agents_host/")
  end

  defp publish_order(_args), do: Enum.each(@publish, &IO.puts/1)

  defp release_packages([tag]) do
    packages =
      case Regex.run(~r/^(?:([a-z_]+)-)?v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/, tag) do
        [_, "", _, _, "0"] -> @family
        [_, "aws_event_stream", _, _, _] -> ["aws_event_stream"]
        [_, package, _, _, patch] when package in @family and patch != "0" -> [package]
        _ -> Mix.raise("invalid release tag: #{tag}")
      end

    Enum.each(packages, &IO.puts/1)
  end

  defp release_packages(_), do: Mix.raise("usage: mix release_packages TAG")

  # Reads a package's version from its own mix.exs, for the publish guard.
  defp package_version([package]) do
    version =
      Mix.Project.in_project(String.to_atom(package), package, fn _module ->
        Mix.Project.config()[:version]
      end)

    IO.puts(version)
  end
end
