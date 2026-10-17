defmodule ReqManagedAgents.Acceptance.Proposal do
  @moduledoc "Credential-free description of an explicitly selected acceptance run."
  alias ReqManagedAgents.Acceptance.{Bounds, Config}
  @enforce_keys [:config_digest, :config, :resource, :actions, :required_assertions]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          config_digest: String.t(),
          config: Config.t(),
          resource: %{String.t() => Jason.Encoder.t()},
          actions: [String.t()],
          required_assertions: [String.t()]
        }

  @doc "Construct a proposal without resolving credentials or discovering resources."
  @spec new(Config.t()) :: {:ok, t()} | {:error, Config.error()}
  def new(%Config{} = candidate) do
    with {:ok, config} <- Config.new(candidate) do
      {:ok,
       %__MODULE__{
         config_digest: config.digest,
         config: config,
         resource: config.resource,
         actions: actions(config.provider),
         required_assertions: ~w(native_activity native_completion bounded_capture)
       }}
    end
  end

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
      "prerequisites" => [
        "selected_resource",
        "externally_supplied_credentials",
        "external_authorization"
      ]
    }
  end

  defp actions(:agentcore), do: ["invoke_selected_resource", "record_bounded_evidence"]

  defp actions(:claude_managed_agents),
    do: [
      "create_budgeted_session",
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
