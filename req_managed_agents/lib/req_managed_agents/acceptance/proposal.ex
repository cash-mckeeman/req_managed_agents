defmodule ReqManagedAgents.Acceptance.Proposal do
  @moduledoc "Credential-free description of an explicitly selected acceptance run."
  alias ReqManagedAgents.Acceptance.{Bounds, Config}
  alias ReqManagedAgents.CloudWatch.Query
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.RecoveryExpectation
  @enforce_keys [:config_digest, :config, :resource, :actions, :required_assertions]
  defstruct @enforce_keys ++ [selection: nil]

  @typedoc "Selection is an opaque validated provider-owned handle, interpreted only by its scenario edge. Native references are never rendered."
  @type t :: %__MODULE__{
          config_digest: String.t(),
          config: Config.t(),
          resource: %{String.t() => Jason.Encoder.t()},
          actions: [String.t()],
          required_assertions: [String.t()],
          selection: Query.t() | RecoveryExpectation.t() | nil
        }

  @doc "Construct a proposal without resolving credentials or discovering resources."
  @spec new(Config.t(), Query.t() | RecoveryExpectation.t() | nil) ::
          {:ok, t()} | {:error, Config.error()}
  def new(candidate, selection \\ nil)

  def new(%Config{} = candidate, selection)
      when is_nil(selection) or is_struct(selection, Query) or
             is_struct(selection, RecoveryExpectation) do
    with {:ok, config} <- Config.new(candidate), {:ok, required} <- required(config.scenario) do
      {:ok,
       %__MODULE__{
         config_digest: config.digest,
         config: config,
         resource: config.resource,
         actions: actions(config.provider) ++ evidence_actions(config),
         required_assertions: required,
         selection: selection
       }}
    end
  end

  def new(_, _), do: {:error, :invalid_config}

  @doc "Render proposal metadata without native resource references or scenario payloads."
  @spec to_wire(t()) :: %{String.t() => Jason.Encoder.t()}
  def to_wire(%__MODULE__{} = proposal) do
    %{
      "schema_version" => 1,
      "config_digest" => proposal.config_digest,
      "provider" => provider(proposal.config.provider),
      "scenario" => scenario(proposal.config.scenario),
      "source_revision" => proposal.config.source_revision,
      "source_identity" => "declared",
      "actions" => proposal.actions,
      "required_assertions" => proposal.required_assertions,
      "bounds" => Bounds.to_wire(proposal.config.bounds),
      "retain_until" => DateTime.to_iso8601(proposal.config.retain_until),
      "content" => Atom.to_string(proposal.config.content),
      "prerequisites" =>
        prerequisites(proposal.config) ++
          [
            "selected_resource",
            "externally_supplied_credentials",
            "external_authorization"
          ]
    }
  end

  defp required(:basic), do: {:ok, ~w(native_activity native_completion bounded_capture)}

  defp required(:evidence),
    do: {:ok, ~w(native_activity native_completion bounded_capture stored_evidence)}

  defp required(:tool_recovery),
    do:
      {:ok,
       ~w(native_activity native_completion bounded_capture stored_evidence native_tool_recovery)}

  defp required(_), do: {:error, :invalid_config}

  defp prerequisites(%Config{provider: :claude_managed_agents, scenario: :tool_recovery}),
    do: ["selected_agent_builtin_tool_capability"]

  defp prerequisites(_), do: []

  defp evidence_actions(%Config{provider: :agentcore, scenario: :evidence}),
    do: ["read_selected_isolated_log_group"]

  defp evidence_actions(_), do: []

  defp actions(:agentcore), do: ["invoke_selected_resource", "record_bounded_evidence"]

  defp actions(:claude_managed_agents),
    do: [
      "create_budgeted_session",
      "archive_on_budget_mismatch",
      "send_selected_prompt",
      "record_bounded_evidence",
      "read_bounded_history",
      "external_owned_session_cleanup"
    ]

  defp provider(:agentcore), do: "agentcore"
  defp provider(:claude_managed_agents), do: "claude-managed-agents"
  defp scenario(:tool_recovery), do: "tool-recovery"
  defp scenario(value), do: Atom.to_string(value)
end
