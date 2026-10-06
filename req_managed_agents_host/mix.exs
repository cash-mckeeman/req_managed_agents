defmodule ReqManagedAgentsHost.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/cash-mckeeman/req_managed_agents_host"

  def project do
    [
      app: :req_managed_agents_host,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Durable single-node session host for req_managed_agents: crash-survivable, " <>
          "idle-detachable hosted sessions keyed by an external id.",
      package: package(),
      name: "req_managed_agents_host",
      source_url: @source_url,
      docs: docs(),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [mod: {ReqManagedAgents.Host.Application, []}, extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      sibling(:req_managed_agents, @version),
      {:jason, "~> 1.4"},
      {:mox, "~> 1.1", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Path in development; from Hex when publishing. The requirement is the family
  # minor of `version` unless a patch needs a sibling's patch, which passes its
  # own floor. Public so the test can drive it with any version and requirement.
  @doc false
  def sibling(app, version, requirement \\ nil) do
    case System.get_env("RMA_PUBLISH") do
      "1" -> {app, requirement || family_minor(version)}
      "floor" -> {app, "== " <> requirement_floor(requirement || family_minor(version))}
      _ -> {app, path: "../#{app}"}
    end
  end

  # The family minor of a version: "~> 0.3.0" for 0.3.7.
  defp family_minor(version) do
    %Version{major: major, minor: minor} = Version.parse!(version)
    "~> #{major}.#{minor}.0"
  end

  # "~> 0.12.1" -> "0.12.1": the lowest version the requirement admits. Not named
  # `floor/1`: that clashes with the auto-imported Kernel.floor/1 and the module
  # does not compile.
  defp requirement_floor("~> " <> version) do
    {:ok, _} = Version.parse(version)
    version
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      maintainers: ["cash-mckeeman"],
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [main: "readme", extras: ["README.md", "CHANGELOG.md", "LICENSE"], source_ref: "v#{@version}"]
  end

  defp dialyzer do
    [
      # Keep PLTs under priv/plts so CI can cache them across runs.
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      # :ex_unit — test/support (StoreContract) imports ExUnit.Assertions and CI
      # dialyzes under MIX_ENV=test; :mix covers any Mix.* calls in tooling.
      plt_add_apps: [:mix, :ex_unit]
    ]
  end
end
