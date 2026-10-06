defmodule ReqManagedAgents.Host.DepDirectionTest do
  @moduledoc """
  req_managed_agents_host's runtime deps are exactly req_managed_agents and
  jason, whichever way RMA_PUBLISH resolves the sibling (a path in
  development, a Hex requirement when publishing). Every module it ships is
  under ReqManagedAgents.Host, so it can never define a module
  req_managed_agents owns. `only:` deps are filtered out.
  """
  use ExUnit.Case, async: false

  alias ReqManagedAgents.Host.Test.RMAPublishEnv

  test "runtime deps are exactly req_managed_agents and jason, in every RMA_PUBLISH mode" do
    for mode <- [nil, "1", "floor"] do
      deps = RMAPublishEnv.with_value(mode, fn -> Mix.Project.get!().project()[:deps] end)
      names = runtime_names(deps)

      assert names == [:jason, :req_managed_agents],
             "RMA_PUBLISH=#{inspect(mode)}: runtime deps #{inspect(names)}"
    end
  end

  test "every module this package ships is under ReqManagedAgents.Host" do
    shipped = shipped_modules()

    assert shipped != []
    assert Enum.reject(shipped, &owned?/1) == []
  end

  defp runtime_names(deps) do
    deps
    |> Enum.reject(&Keyword.has_key?(opts(&1), :only))
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp opts({_app, opts}) when is_list(opts), do: opts
  defp opts({_app, _requirement}), do: []
  defp opts({_app, _requirement, opts}), do: opts

  # Modules compiled from lib/; test/support modules (StubProvider and the
  # rest) are compiled into the app under MIX_ENV=test and are not shipped.
  defp shipped_modules do
    {:ok, modules} = :application.get_key(:req_managed_agents_host, :modules)
    Enum.filter(modules, &from_lib?/1)
  end

  defp from_lib?(module) do
    module.module_info(:compile)[:source]
    |> List.to_string()
    |> Path.relative_to_cwd()
    |> String.starts_with?("lib/")
  end

  # A protocol implementation (`@derive Jason.Encoder` on a Host struct
  # compiles to Jason.Encoder.ReqManagedAgents.Host.…) is owned through the
  # struct it implements the protocol for.
  defp owned?(module) do
    Code.ensure_loaded!(module)

    if function_exported?(module, :__impl__, 1),
      do: host_module?(module.__impl__(:for)),
      else: host_module?(module)
  end

  defp host_module?(module) do
    module == ReqManagedAgents.Host or
      String.starts_with?(Atom.to_string(module), "Elixir.ReqManagedAgents.Host.")
  end
end
