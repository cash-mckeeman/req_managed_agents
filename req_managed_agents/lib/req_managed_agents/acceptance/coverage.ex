defmodule ReqManagedAgents.Acceptance.Coverage.Source do
  @moduledoc "Acquisition status and counts for one captured native source."
  @enforce_keys [:source_id, :kind, :status, :pages, :records_seen, :session_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source_id: String.t(),
          kind: atom(),
          status: atom(),
          pages: non_neg_integer(),
          records_seen: non_neg_integer(),
          session_id: String.t() | nil
        }
end

defmodule ReqManagedAgents.Acceptance.Coverage.Limits do
  @moduledoc "Configured native session and persisted-history acquisition limits."
  @enforce_keys [:invocations, :history_pages]
  defstruct @enforce_keys
  @type t :: %__MODULE__{invocations: pos_integer(), history_pages: non_neg_integer()}
end

defmodule ReqManagedAgents.Acceptance.Coverage do
  @moduledoc "Source coverage and local stopping policy are separate from native completion."
  alias ReqManagedAgents.Acceptance.{Config, Observation}
  alias ReqManagedAgents.Acceptance.Coverage.{Limits, Source}
  alias ReqManagedAgents.Evidence.Capture
  @enforce_keys [:sources, :local_observations, :limits, :limitations]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          sources: [Source.t()],
          local_observations: [Observation.t()],
          limits: Limits.t(),
          limitations: [String.t()]
        }

  @doc "Project coverage without copying provider payloads."
  @spec new(Config.t(), Capture.t() | nil, [Observation.t()]) :: {:ok, t()}
  def new(config, capture, observations) do
    sources =
      if capture,
        do:
          Enum.map(
            capture.sources,
            &%Source{
              source_id: &1.id,
              kind: &1.kind,
              status: &1.status,
              pages: &1.pages,
              records_seen: &1.records_seen,
              session_id: capture.session_id
            }
          ),
        else: []

    limitations = [
      "invocations_are_native_session_opens_not_http_requests",
      "local_first_turn_halt_is_not_native_completion",
      "response_buffer_not_capture_byte_bound"
    ]

    limitations =
      if config.provider == :agentcore and config.scenario == :evidence,
        do:
          limitations ++
            ["sessionassociation_not_tracejoin", "isolated_destination_is_caller_selected"],
        else: limitations

    limitations =
      if config.provider == :claude_managed_agents and config.scenario == :evidence,
        do: limitations ++ ["stored_activity_does_not_verify_tool_arguments_or_recovery"],
        else: limitations

    limitations =
      if config.provider == :claude_managed_agents and config.scenario == :tool_recovery,
        do:
          limitations ++
            [
              "server_budget_may_overshoot_inflight_requests",
              "builtin_tool_count_is_not_client_bounded",
              "final_content_policy_does_not_attest_argument_availability"
            ],
        else: limitations

    {:ok,
     %__MODULE__{
       sources: sources,
       local_observations: observations,
       limits: %Limits{
         invocations: config.bounds.calls,
         history_pages: Map.get(config.inputs, "history_pages", 0)
       },
       limitations: limitations
     }}
  end

  @doc "Render source metadata and the explicit local halt independently."
  @spec to_wire(t()) :: %{String.t() => Jason.Encoder.t()}
  def to_wire(coverage) do
    %{
      "sources" =>
        Enum.map(
          coverage.sources,
          &%{
            "source_id" => &1.source_id,
            "kind" => Atom.to_string(&1.kind),
            "status" => Atom.to_string(&1.status),
            "pages" => &1.pages,
            "records_seen" => &1.records_seen,
            "session_id" => &1.session_id
          }
        ),
      "local_observations" =>
        Enum.map(
          coverage.local_observations,
          &%{"name" => &1.name, "outcome" => Atom.to_string(&1.outcome)}
        ),
      "limits" => %{
        "invocations" => coverage.limits.invocations,
        "history_pages" => coverage.limits.history_pages
      },
      "limitations" => coverage.limitations
    }
  end
end
