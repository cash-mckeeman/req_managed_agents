defmodule ReqManagedAgents.DepDirectionTest do
  @moduledoc """
  req_managed_agents never depends on req_managed_agents_host, which lives in
  the same repository and inside this package's module namespace. Checked
  twice: the declared runtime deps, and the modules and source this package
  ships. `only:` deps (dev and test tooling) are not runtime deps and are
  filtered out.
  """
  use ExUnit.Case, async: true

  @required [:finch, :jason, :req, :telemetry]
  @optional [:aws_event_stream, :ex_aws_auth, :req_llm]

  test "runtime deps are exactly the allowed set" do
    deps = Enum.reject(Mix.Project.config()[:deps], &Keyword.has_key?(opts(&1), :only))

    assert names(Enum.reject(deps, &optional?/1)) == @required
    assert names(Enum.filter(deps, &optional?/1)) == @optional
  end

  test "no module of this package is ReqManagedAgents.Host or under it" do
    {:ok, modules} = :application.get_key(:req_managed_agents, :modules)

    assert Enum.filter(modules, &host_module?/1) == []
  end

  test "no source file under lib/ names ReqManagedAgents.Host" do
    paths = Path.wildcard("lib/**/*.{ex,exs}")

    # A scan over an empty list passes vacuously, and a glob that stops at the
    # top level misses the nested files: name a top-level and a nested one.
    assert "lib/req_managed_agents.ex" in paths
    assert "lib/mix/tasks/req_managed_agents.qa_checkpoint.ex" in paths

    offenders = for path <- paths, File.read!(path) =~ ~r/ReqManagedAgents\.Host\b/, do: path

    assert offenders == []
  end

  defp names(deps) do
    deps
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp optional?(dep), do: Keyword.get(opts(dep), :optional, false)

  defp opts({_app, opts}) when is_list(opts), do: opts
  defp opts({_app, _requirement}), do: []
  defp opts({_app, _requirement, opts}), do: opts

  defp host_module?(module) do
    module == ReqManagedAgents.Host or
      String.starts_with?(Atom.to_string(module), "Elixir.ReqManagedAgents.Host.")
  end
end
