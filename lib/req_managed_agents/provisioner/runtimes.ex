defmodule ReqManagedAgents.Provisioner.Runtimes do
  @moduledoc """
  Runtime declarations for environment specs: validation, bootstrap script
  rendering, and host allowlist queries.

  A runtime entry is a map (or `ReqManagedAgents.Provisioner.Runtime.t()`
  struct) with three keys:

  - `:lang` — atom identifying the language (e.g. `:elixir`, `:erlang`)
  - `:version` — binary version string (e.g. `"1.17.0"`)
  - `:via` — installation mechanism; only `:mise` is currently supported

  Shape and version-charset validation lives in `Runtime.new/1`, the single
  gate every entry passes through before it can reach rendering.

  The runtimes list lives inside the env spec and is therefore covered by the
  spec digest — different runtimes produce a different image name automatically.
  """

  alias ReqManagedAgents.Provisioner.Runtime

  @doc """
  Validates a runtimes list. Non-list input is rejected with the same error
  shape as an invalid entry.

  Returns `:ok` or `{:error, {:invalid_runtime, entry}}`.
  """
  @spec validate(term()) :: :ok | {:error, {:invalid_runtime, term()}}
  def validate(runtimes) when is_list(runtimes) do
    Enum.reduce_while(runtimes, :ok, fn entry, :ok ->
      case Runtime.new(entry) do
        {:ok, _runtime} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
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
  @spec bootstrap_script([map() | Runtime.t()]) :: binary()
  def bootstrap_script(runtimes) do
    entries = runtimes |> coerce() |> ordered_specs()
    template = Path.join([priv_dir(), "runtime_bootstrap", "mise_install.sh.eex"])
    EEx.eval_file(template, entries: entries)
  end

  @doc """
  Renders the system-prompt instruction block for the given runtime entries.

  The block states which runtimes the session declares, instructs the agent to
  run the bootstrap script EXACTLY ONCE via bash before the first command that
  needs the runtimes (the script is idempotent), and embeds the full
  `bootstrap_script/1` output in a fenced code block.

  Output is deterministic: the same input always produces an identical binary.
  """
  @spec system_prompt_block([map() | Runtime.t()]) :: binary()
  def system_prompt_block(runtimes) do
    structs = coerce(runtimes)
    declared = Enum.map_join(structs, ", ", &"#{&1.lang} #{&1.version}")

    """
    ## Runtime bootstrap

    This session's environment declares the following runtimes: #{declared}.
    They are NOT preinstalled. Before the first command that needs them, run
    the bootstrap script below EXACTLY ONCE via bash (it is idempotent, so an
    accidental repeat is safe but wasteful). It installs mise, the declared
    runtimes, and persists PATH + locale to ~/.bashrc for subsequent commands.

    ```bash
    #{String.trim_trailing(bootstrap_script(structs))}
    ```
    """
  end

  @doc """
  Returns the hosts required for the given runtimes, deduplicated and sorted.

  Reads `priv/runtime_bootstrap/allowed_hosts.json` at runtime. Returns `[]`
  for an empty runtimes list.
  """
  @spec required_hosts([map() | Runtime.t()]) :: [binary()]
  def required_hosts([]), do: []

  def required_hosts(runtimes) do
    structs = coerce(runtimes)

    if Enum.any?(structs, &(&1.via == :mise)) do
      mise_hosts()
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Coerces a list of maps/structs to %Runtime{} structs, re-running the
  # shape+charset gate in `Runtime.new/1` for every entry (idempotent on an
  # already-valid struct). Every render path funnels through this — entries
  # reaching here are expected to have already passed `validate/1`.
  defp coerce(runtimes) do
    Enum.map(runtimes, fn entry ->
      case Runtime.new(entry) do
        {:ok, runtime} ->
          runtime

        {:error, _reason} = error ->
          raise ArgumentError, "invalid runtime entry: #{inspect(error)}"
      end
    end)
  end

  defp ordered_specs(runtimes) do
    erlang = Enum.find(runtimes, &(&1.lang == :erlang))
    elixir_entry = Enum.find(runtimes, &(&1.lang == :elixir))
    others = Enum.reject(runtimes, &(&1.lang in [:erlang, :elixir]))
    other_specs = Enum.map(others, &"#{&1.lang}@#{&1.version}")

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
