defmodule ReqManagedAgents.Acceptance.Report do
  @moduledoc "Version-one acceptance results; provider evidence is stored separately."
  alias ReqManagedAgents.Acceptance.{Assertion, Bounds, Cleanup, Config, Consumption, Coverage}
  alias ReqManagedAgents.Evidence.Artifact.Ref

  @enforce_keys [
    :config,
    :observed_source_revision,
    :outcome,
    :assertions,
    :coverage,
    :bounds,
    :artifacts,
    :cleanup,
    :required_assertions,
    :consumed
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          config: Config.t(),
          observed_source_revision: String.t(),
          outcome: Assertion.outcome(),
          assertions: [Assertion.t()],
          coverage: Coverage.t(),
          bounds: Bounds.t(),
          artifacts: [Ref.t()],
          cleanup: Cleanup.t(),
          required_assertions: [String.t()],
          consumed: Consumption.t()
        }

  @doc "Missing, duplicate or unexpected predicates fail the assessment."
  @spec outcome([String.t()], [Assertion.t()]) :: Assertion.outcome()
  def outcome(required, assertions) do
    names = Enum.map(assertions, & &1.name)

    cond do
      required == [] or Enum.sort(names) != Enum.sort(required) or
          length(Enum.uniq(names)) != length(names) ->
        :failed

      Enum.any?(assertions, &(&1.outcome == :failed)) ->
        :failed

      Enum.any?(assertions, &(&1.outcome == :inconclusive)) ->
        :inconclusive

      Enum.any?(assertions, &(&1.outcome == :unsupported)) ->
        :unsupported

      true ->
        :passed
    end
  end

  @doc "Render the stable runner interface, with canonical artifact hashes."
  @spec to_wire(t()) :: %{String.t() => Jason.Encoder.t()}
  def to_wire(%__MODULE__{} = report) do
    %{
      "schema_version" => 1,
      "required_assertions" => report.required_assertions,
      "config_digest" => report.config.digest,
      "requested_source_revision" => report.config.source_revision,
      "observed_source_revision" => report.observed_source_revision,
      "provider" => selector(report.config.provider),
      "scenario" => selector(report.config.scenario),
      "outcome" => Atom.to_string(report.outcome),
      "assertions" => Enum.map(report.assertions, &Assertion.to_wire/1),
      "coverage" => Coverage.to_wire(report.coverage),
      "bounds" => %{
        "configured" => Bounds.to_wire(report.bounds),
        "consumed" => Consumption.to_wire(report.consumed)
      },
      "artifacts" =>
        Enum.map(report.artifacts, &%{"relative_path" => &1.relative_path, "sha256" => &1.sha256}),
      "cleanup" => Cleanup.to_wire(report.cleanup)
    }
  end

  defp selector(:claude_managed_agents), do: "claude-managed-agents"
  defp selector(:tool_recovery), do: "tool-recovery"
  defp selector(value), do: Atom.to_string(value)
end
