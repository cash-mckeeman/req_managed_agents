defmodule ReqManagedAgents.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/cash-mckeeman/req_managed_agents"

  def project do
    [
      app: :req_managed_agents,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Elixir client for Anthropic's Claude Managed Agents — Anthropic runs the loop, your tools run locally.",
      package: package(),
      docs: docs(),
      dialyzer: dialyzer(),
      name: "ReqManagedAgents",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ReqManagedAgents.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:finch, "~> 0.18"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      # Req.Test (used to stub HTTP in unary tests) needs Plug; Req lists it as
      # optional, so declare it explicitly rather than relying on a transitive dep.
      {:plug, "~> 1.0", only: :test},
      # Bypass runs a real chunked HTTP server for the SSE Stream/Session tests.
      {:bypass, "~> 2.1", only: :test},
      {:ex_aws_auth, "~> 1.4"},
      {:aws_event_stream, "~> 0.1"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp dialyzer do
    [
      # Keep PLTs under priv/plts so CI can cache them across runs.
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      # Mix tasks call Mix.shell/Mix.raise; Mix isn't in the core PLT.
      plt_add_apps: [:mix],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      maintainers: ["bizinsights"]
    ]
  end

  defp docs do
    [main: "readme", extras: ["README.md"]]
  end
end
