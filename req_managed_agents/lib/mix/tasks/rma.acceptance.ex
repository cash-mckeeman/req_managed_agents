defmodule Mix.Tasks.Rma.Acceptance do
  @shortdoc "Propose a bounded managed-provider acceptance run"
  @moduledoc """
  Proposes one selected scenario without resolving credentials or calling providers.
  Requires `--provider`, `--scenario` and `--config`. Optional `--out` writes a
  new private run root. Live execution requires `--execute DIGEST` and
  `--approval-ref TEXT`; a reference does not grant external authorization.
  """
  use Mix.Task
  alias ReqManagedAgents.Acceptance
  alias ReqManagedAgents.Acceptance.{Config, Proposal}

  @switches [
    provider: :string,
    scenario: :string,
    config: :string,
    out: :string,
    execute: :string,
    approval_ref: :string
  ]

  @impl Mix.Task
  def run(argv) do
    with {:ok, proposal, :proposal, out} <- prepare(argv),
         :ok <- emit(proposal, out) do
      :ok
    else
      {:error, reason} -> Mix.raise("acceptance refused: #{reason}")
    end
  end

  @doc "Validate the complete command before any credential or provider activity."
  @spec prepare([String.t()]) ::
          {:ok, Proposal.t(), :proposal, String.t() | nil} | {:error, atom()}
  def prepare(argv) do
    with {:ok, opts} <- options(argv),
         {:ok, provider, scenario} <- Config.selectors(opts[:provider], opts[:scenario]),
         {:ok, bytes} <- read_config(opts[:config]),
         {:ok, config} <- Config.parse(bytes),
         true <- config.provider == provider and config.scenario == scenario,
         :ok <- output(opts[:out]),
         :ok <- execution(opts, config),
         {:ok, proposal} <- Acceptance.propose(config) do
      {:ok, proposal, :proposal, opts[:out]}
    else
      false -> {:error, :selector_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp options(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: Enum.map(@switches, fn {key, type} -> {key, [type, :keep]} end)
      )

    keys = Keyword.keys(opts)

    if rest == [] and invalid == [] and length(keys) == length(Enum.uniq(keys)),
      do: {:ok, opts},
      else: {:error, :invalid_switches}
  end

  defp read_config(path) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> {:error, :config_unreadable}
    end
  end

  defp read_config(_), do: {:error, :config_required}
  defp output(nil), do: :ok

  defp output(path) do
    case {File.lstat(path), File.lstat(Path.dirname(path))} do
      {{:error, :enoent}, {:ok, %File.Stat{type: :directory, mode: mode}}} ->
        if Bitwise.band(mode, 0o077) == 0 and safe_ancestors?(Path.dirname(path)) and
             owned?(Path.dirname(path)),
           do: :ok,
           else: {:error, :output_ownership}

      _ ->
        {:error, :output_collision}
    end
  end

  defp safe_ancestors?(path) do
    expanded = Path.expand(path)
    parts = Path.split(expanded)

    Enum.reduce_while(parts, "", fn part, prefix ->
      next = if prefix == "", do: part, else: Path.join(prefix, part)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, next}
        _ -> {:halt, false}
      end
    end) != false and not Enum.member?(Path.split(path), "..")
  end

  defp owned?(path) do
    case {System.cmd("id", ["-u"]), File.lstat(path)} do
      {{uid, 0}, {:ok, %File.Stat{uid: owner}}} -> String.trim(uid) == Integer.to_string(owner)
      _ -> false
    end
  end

  defp execution(opts, %Config{digest: digest}) do
    case {opts[:execute], opts[:approval_ref]} do
      {nil, nil} ->
        :ok

      {^digest, approval} when is_binary(approval) ->
        if String.trim(approval) == "",
          do: {:error, :approval_required},
          else: {:error, :runner_unavailable}

      {nil, _} ->
        {:error, :execute_required}

      _ ->
        {:error, :digest_mismatch}
    end
  end

  defp emit(proposal, _out) do
    proposal |> Proposal.to_wire() |> Jason.encode!() |> Mix.shell().info()
    :ok
  end
end
