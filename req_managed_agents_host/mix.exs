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
      {:req_managed_agents, "~> 0.11.0"},
      {:jason, "~> 1.4"},
      {:mox, "~> 1.1", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
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
