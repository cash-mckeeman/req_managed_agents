defmodule Mix.Tasks.Rma.Acceptance do
  @shortdoc "Propose a bounded managed-provider acceptance run"
  @moduledoc """
  Proposes one selected scenario without resolving credentials or calling providers.
  Requires `--provider`, `--scenario` and `--config`. Optional `--out` validates a
  nonexisting private run root; proposal mode creates and reserves nothing. Live execution requires `--execute DIGEST` and
  `--approval-ref TEXT`; a reference does not grant external authorization.
  """
  use Mix.Task
  @requirements ["compile"]
  alias ReqManagedAgents.Acceptance
  alias ReqManagedAgents.Acceptance.{Config, Output, Proposal, Report}

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
    case prepare(argv) do
      {:ok, proposal, :proposal, _out} ->
        emit(proposal)

      {:ok, proposal, {:execute, approval}, out} ->
        case Acceptance.run(proposal.config,
               out: out,
               execute: proposal.config_digest,
               approval_ref: approval
             ) do
          {:ok, report} ->
            report |> Report.to_wire() |> Jason.encode!() |> Mix.shell().info()

          {:error, %Report{} = report} ->
            report |> Report.to_wire() |> Jason.encode!() |> Mix.shell().info()
            Mix.raise("acceptance did not pass")

          {:error, reason} ->
            Mix.raise("acceptance refused: #{reason}")
        end

      {:error, reason} ->
        Mix.raise("acceptance refused: #{reason}")
    end
  end

  @doc "Validate the complete command before any credential or provider activity."
  @spec prepare([String.t()]) ::
          {:ok, Proposal.t(), :proposal | {:execute, String.t()}, String.t() | nil}
          | {:error, atom()}
  def prepare(argv) do
    with {:ok, opts} <- options(argv),
         {:ok, provider, scenario} <- Config.selectors(opts[:provider], opts[:scenario]),
         {:ok, bytes} <- read_config(opts[:config]),
         {:ok, config} <- Config.parse(bytes),
         true <- config.provider == provider and config.scenario == scenario,
         :ok <- Output.validate(opts[:out]),
         {:ok, mode} <- execution(opts, config),
         {:ok, proposal} <- Acceptance.propose(config) do
      {:ok, proposal, mode, opts[:out]}
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

  defp execution(opts, %Config{digest: digest}) do
    case {opts[:execute], opts[:approval_ref]} do
      {nil, nil} ->
        {:ok, :proposal}

      {^digest, approval} when is_binary(approval) ->
        execution_approval(approval, opts[:out])

      {nil, _} ->
        {:error, :execute_required}

      _ ->
        {:error, :digest_mismatch}
    end
  end

  defp execution_approval(approval, out) do
    cond do
      String.trim(approval) == "" -> {:error, :approval_required}
      not is_binary(out) -> {:error, :output_required}
      true -> {:ok, {:execute, approval}}
    end
  end

  defp emit(proposal) do
    proposal |> Proposal.to_wire() |> Jason.encode!() |> Mix.shell().info()
    :ok
  end
end
