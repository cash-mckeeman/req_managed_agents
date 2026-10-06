defmodule ReqManagedAgentsRoot.MixProject do
  use Mix.Project

  # Publish order. A package is published only while it is listed here.
  @publish ~w(req_managed_agents req_managed_agents_host)

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
      package_version: &package_version/1
    ]
  end

  defp refuse_root_test(_args) do
    Mix.raise("run mix test from req_managed_agents/ or req_managed_agents_host/")
  end

  defp publish_order(_args), do: Enum.each(@publish, &IO.puts/1)

  # Reads a package's version from its own mix.exs, for the publish guard.
  defp package_version([package]) do
    version =
      Mix.Project.in_project(String.to_atom(package), package, fn _module ->
        Mix.Project.config()[:version]
      end)

    IO.puts(version)
  end
end
