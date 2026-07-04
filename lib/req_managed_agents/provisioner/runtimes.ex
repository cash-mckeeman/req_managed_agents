defmodule ReqManagedAgents.Provisioner.Runtimes do
  @moduledoc """
  Runtime declarations for environment specs: validation, bootstrap script
  rendering, and host allowlist queries.

  A runtime entry is a map with three required keys:

  - `:lang` — atom identifying the language (e.g. `:elixir`, `:erlang`)
  - `:version` — binary version string (e.g. `"1.17.0"`)
  - `:via` — installation mechanism; only `:mise` is currently supported

  The runtimes list lives inside the env spec and is therefore covered by the
  spec digest — different runtimes produce a different image name automatically.
  """

  @doc """
  Validates a runtimes list. Non-list input is rejected with the same error
  shape as an invalid entry.

  Returns `:ok` or `{:error, {:invalid_runtime, entry}}`.
  """
  @spec validate(term()) :: :ok | {:error, {:invalid_runtime, term()}}
  def validate(runtimes) when is_list(runtimes) do
    case Enum.find(runtimes, &(not valid_entry?(&1))) do
      nil -> :ok
      entry -> {:error, {:invalid_runtime, entry}}
    end
  end

  def validate(input), do: {:error, {:invalid_runtime, input}}

  @doc """
  Renders the mise bootstrap install script for the given runtime entries.

  Ordering rules:
  - Erlang is placed before elixir when both are present.
  - Elixir version becomes `elixir@<version>-otp-<erlang_major>` when an
    erlang entry exists; plain `elixir@<version>` otherwise.
  - Other languages render as `<lang>@<version>` verbatim.
  - Languages beyond erlang/elixir retain their input order after the pair.

  Output is deterministic: the same input always produces an identical binary.
  """
  @spec bootstrap_script([map()]) :: binary()
  def bootstrap_script(runtimes) do
    entries = ordered_specs(runtimes)
    template = Path.join([priv_dir(), "runtime_bootstrap", "mise_install.sh.eex"])
    EEx.eval_file(template, entries: entries)
  end

  @doc """
  Returns the hosts required for the given runtimes, deduplicated and sorted.

  Reads `priv/runtime_bootstrap/allowed_hosts.json` at runtime. Returns `[]`
  for an empty runtimes list.
  """
  @spec required_hosts([map()]) :: [binary()]
  def required_hosts([]), do: []

  def required_hosts(runtimes) do
    if Enum.any?(runtimes, &(&1[:via] == :mise)) do
      mise_hosts()
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Shape check in the guard; version format in the body (regex is not
  # guard-safe). The charset closes shell injection through the rendered
  # script (no whitespace/`;`/quotes) and rejects the empty string.
  defp valid_entry?(%{lang: lang, version: version, via: :mise})
       when is_atom(lang) and is_binary(version),
       do: version =~ ~r/\A[0-9A-Za-z.\-+]+\z/

  defp valid_entry?(_), do: false

  defp ordered_specs(runtimes) do
    erlang = Enum.find(runtimes, &(&1[:lang] == :erlang))
    elixir_entry = Enum.find(runtimes, &(&1[:lang] == :elixir))
    others = Enum.reject(runtimes, &(&1[:lang] in [:erlang, :elixir]))
    other_specs = Enum.map(others, &"#{&1[:lang]}@#{&1[:version]}")

    [build_erlang_spec(erlang), build_elixir_spec(elixir_entry, erlang) | other_specs]
    |> Enum.reject(&is_nil/1)
  end

  defp build_erlang_spec(nil), do: nil
  defp build_erlang_spec(%{version: version}), do: "erlang@#{version}"

  defp build_elixir_spec(nil, _erlang), do: nil
  defp build_elixir_spec(%{version: version}, nil), do: "elixir@#{version}"

  defp build_elixir_spec(%{version: elixir_version}, %{version: erlang_version}),
    do: "elixir@#{elixir_version}-otp-#{erlang_major(erlang_version)}"

  defp erlang_major(version), do: version |> String.split(".") |> hd()

  defp mise_hosts do
    path = Path.join([priv_dir(), "runtime_bootstrap", "allowed_hosts.json"])
    %{"mise" => hosts} = path |> File.read!() |> Jason.decode!()
    hosts |> Enum.uniq() |> Enum.sort()
  end

  defp priv_dir do
    case :code.priv_dir(:req_managed_agents) do
      {:error, _} ->
        raise RuntimeError,
              "priv/runtime_bootstrap unavailable for :req_managed_agents — " <>
                "ensure priv/ ships in the package"

      dir ->
        to_string(dir)
    end
  end
end
