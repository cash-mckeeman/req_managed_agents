defmodule AWSEventStream.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/cash-mckeeman/req_managed_agents"

  def project do
    [
      app: :aws_event_stream,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Pure-Elixir codec for the AWS vnd.amazon.eventstream binary protocol (encode + decode).",
      package: package(),
      docs: docs(),
      dialyzer: dialyzer(),
      source_url: @source_url,
      name: "AWSEventStream"
    ]
  end

  def application, do: []

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4", optional: true},
      {:stream_data, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp dialyzer do
    [
      # Keep PLTs under priv/plts so CI can cache them across runs.
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      # The maintainer-only sync task calls Mix and OTP HTTP/TLS apps that the
      # library itself doesn't depend on — add them to the PLT only. :public_key
      # is deliberately absent: dialyzer crashes core-compiling its beams on some
      # OTP builds (seen on 29.0.2), so its two calls are covered by
      # .dialyzer_ignore.exs instead.
      plt_add_apps: [:mix, :inets, :ssl]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # lib/mix/ holds maintainer-only tasks — not shipped to hex consumers.
      files:
        ~w(lib/aws_event_stream lib/aws_event_stream.ex mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "AWSEventStream",
      source_ref: "aws_event_stream-v#{@version}",
      source_url: @source_url,
      source_url_pattern:
        "#{@source_url}/blob/aws_event_stream-v#{@version}/aws_event_stream/%{path}#L%{line}"
    ]
  end
end
