defmodule ReqManagedAgents.Providers.BedrockAgentCore.Acceptance.Evidence do
  @moduledoc "One inline invocation enriched from an explicitly selected isolated CloudWatch group."
  alias ReqManagedAgents.Acceptance.{
    Basic,
    Config,
    Context,
    Observation,
    Proposal,
    StoredEvidence
  }

  alias ReqManagedAgents.CloudWatch.Client, as: LogsClient
  alias ReqManagedAgents.CloudWatch.Evidence, as: LogsEvidence
  alias ReqManagedAgents.CloudWatch.Query
  alias ReqManagedAgents.Evidence.Options
  alias ReqManagedAgents.Providers.BedrockAgentCore.{Acceptance, CloudWatchLogs}

  @doc false
  @spec propose(Config.t()) :: {:ok, Proposal.t()} | {:error, atom()}
  def propose(config) do
    inputs = config.inputs
    base = %{config | inputs: Map.drop(inputs, ~w(history_pages cloudwatch))}

    with true <-
           Enum.sort(Map.keys(inputs)) ==
             ~w(cloudwatch history_pages max_tokens model prompt timeout_seconds),
         :ok <- Acceptance.validate(base),
         true <- is_integer(inputs["history_pages"]) and inputs["history_pages"] > 0,
         {:ok, query} <- query(inputs["cloudwatch"], config.resource) do
      Proposal.new(config, query)
    else
      _ -> {:error, :invalid_provider_config}
    end
  end

  defp query(%{"isolated_destination" => true} = raw, resource) do
    if Enum.sort(Map.keys(raw)) == ~w(from isolated_destination log_group to trace_ids) do
      Query.new(%{
        region: resource["region"],
        session_id: resource["runtime_session_id"],
        log_group: raw["log_group"],
        from: raw["from"],
        to: raw["to"],
        trace_ids: raw["trace_ids"]
      })
    else
      {:error, :invalid_selection}
    end
  end

  defp query(_, _), do: {:error, :invalid_selection}

  @doc false
  @spec acquire(
          Context.t(),
          {:ok, [Observation.t()]} | {:error, term(), [Observation.t()]},
          keyword()
        ) :: {:ok, [Observation.t()]} | {:error, atom(), [Observation.t()]}
  def acquire(context, result, native_transport) do
    observations =
      case result do
        {:ok, observations} -> observations
        {:error, _, observations} -> observations
      end

    with {:ok, prior} <- Basic.capture(context, observations),
         {:ok, options} <-
           Options.new(
             content: :retain,
             max_pages: context.config.inputs["history_pages"],
             max_records: context.config.bounds.records,
             max_bytes: context.config.bounds.bytes,
             timeout_ms: context.deadline - System.monotonic_time(:millisecond)
           ),
         {:ok, client} <- logs_client(context, native_transport),
         {:ok, capture} <-
           LogsEvidence.enrich(prior, context.proposal.selection, options,
             client: client,
             message_association: CloudWatchLogs
           ),
         {:ok, observation} <- Observation.new("bounded_cloudwatch_acquisition", :passed, []) do
      {:ok, observations ++ [%{observation | capture: capture}]}
    else
      _ ->
        {:ok, failure} = Observation.new("cloudwatch_acquisition_unavailable", :failed, [])
        {:error, :evidence_unavailable, observations ++ [failure]}
    end
  end

  defp logs_client(context, transport) do
    case context.transport[:cloudwatch_client] do
      %LogsClient{} = client ->
        LogsClient.new(client)

      nil ->
        case transport[:client] do
          %{credentials: credentials} ->
            LogsClient.new(region: context.proposal.selection.region, credentials: credentials)

          _ ->
            {:error, :invalid_logs_client}
        end

      _ ->
        {:error, :invalid_logs_client}
    end
  end

  @doc false
  @spec assess(Context.t(), [Observation.t()]) :: [ReqManagedAgents.Acceptance.Assertion.t()]
  def assess(context, observations) do
    assertion =
      case Basic.capture(context, observations) do
        {:ok, capture} ->
          StoredEvidence.assess(
            Enum.filter(capture.sources, &(&1.kind == :cloudwatch)),
            capture.records
          )

        _ ->
          StoredEvidence.assess([], [])
      end

    Basic.assess(context, observations, :agentcore) ++ [assertion]
  end
end
