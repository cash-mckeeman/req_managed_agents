defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Acceptance do
  @moduledoc "One fresh budgeted CMA session followed by bounded persisted history."
  @behaviour ReqManagedAgents.Acceptance.Scenario
  alias ReqManagedAgents.Acceptance.Recovery

  alias ReqManagedAgents.Acceptance.{
    Assertion,
    Basic,
    Cleanup,
    Config,
    Observation,
    Proposal,
    StoredEvidence
  }

  alias ReqManagedAgents.Budget
  alias ReqManagedAgents.Evidence.{Options, Validation}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.{Client, History, RecoveryExpectation}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.History.Request

  @impl true
  def propose(%Config{provider: :claude_managed_agents, scenario: scenario} = config)
      when scenario in [:basic, :evidence] do
    with :ok <- validate(config), do: Proposal.new(config)
  end

  def propose(%Config{provider: :claude_managed_agents, scenario: :tool_recovery} = config) do
    with :ok <- validate(config),
         {:ok, expectation} <- RecoveryExpectation.new(config.inputs["expected_tool"]),
         do: Proposal.new(config, expectation)
  end

  def propose(_), do: {:error, :unsupported_scenario}

  @doc false
  @spec validate(Config.t()) :: :ok | {:error, :invalid_provider_config}
  def validate(config) do
    if resource?(config.resource) and inputs?(config) and config.bounds.calls == 1,
      do: :ok,
      else: {:error, :invalid_provider_config}
  end

  defp resource?(%{"reference" => agent, "environment_id" => environment} = resource)
       when is_binary(agent) and is_binary(environment),
       do: map_size(resource) == 2 and String.trim(agent) != "" and String.trim(environment) != ""

  defp resource?(_), do: false

  defp inputs?(%Config{
         scenario: scenario,
         inputs:
           %{"prompt" => prompt, "max_list_cost_cents" => cents, "history_pages" => pages} =
             inputs
       })
       when is_binary(prompt) and is_integer(cents) and cents > 0 and is_integer(pages) and
              pages > 0,
       do: String.trim(prompt) != "" and scenario_inputs?(scenario, inputs)

  defp inputs?(_), do: false

  defp scenario_inputs?(scenario, inputs) when scenario in [:basic, :evidence],
    do: map_size(inputs) == 3

  defp scenario_inputs?(:tool_recovery, inputs),
    do: map_size(inputs) == 4 and Map.has_key?(inputs, "expected_tool")

  defp scenario_inputs?(_, _), do: false

  @impl true
  def run(context) do
    config = context.config
    client = native_client(context)
    {:ok, budget} = Budget.new(%{max_list_cost_cents: config.inputs["max_list_cost_cents"]})

    native = [
      client: client,
      agent_id: config.resource["reference"],
      environment_id: config.resource["environment_id"],
      prompt: config.inputs["prompt"],
      budget: budget
    ]

    case Basic.session(context, ClaudeManagedAgents, native) do
      {:ok, observations} ->
        acquire_history(context, client, observations)

      {:error, {:execution_failed, native_reason}, observations} ->
        {:error, :execution_failed, attach_cleanup(observations, native_reason)}
    end
  end

  defp attach_cleanup(
         observations,
         {:budget_not_confirmed, %{session_id: id, archived: archived}}
       ) do
    with {:ok, id} <- Validation.safe_id(id),
         {:ok, cleanup} <- Cleanup.owned_session(id, archive_status(archived)) do
      Enum.map(observations, &%{&1 | cleanup: cleanup})
    else
      _ -> observations
    end
  end

  defp attach_cleanup(observations, _), do: observations
  defp archive_status(:ok), do: :complete
  defp archive_status({:error, _}), do: :pending
  defp archive_status(_), do: :unknown

  defp native_client(context) do
    client = context.transport[:client] || Client.new()

    %{
      client
      | req_options: Keyword.put(client.req_options, :retry, false),
        receive_timeout: context.config.bounds.timeout_ms
    }
  end

  defp acquire_history(context, client, observations) do
    with {:ok, capture} <- Basic.capture(context, observations),
         true <- is_binary(capture.session_id),
         {:ok, options} <-
           Options.new(
             max_pages: context.config.inputs["history_pages"],
             max_records: context.config.bounds.records,
             max_bytes: context.config.bounds.bytes,
             timeout_ms: context.deadline - System.monotonic_time(:millisecond),
             content: :retain
           ),
         {:ok, request} <- Request.new(client: client, options: options, prior: capture),
         {:ok, history} <- History.fetch(capture.session_id, request),
         {:ok, observation} <-
           Observation.new(
             "bounded_history",
             :passed,
             Enum.map(history.records, &(&1.source_id <> ":" <> &1.id))
           ) do
      {:ok, observations ++ [%{observation | capture: history}]}
    else
      _ ->
        {:ok, failure} = Observation.new("history_unavailable", :failed, [])
        {:error, :history_failed, observations ++ [failure]}
    end
  end

  @impl true
  def assess(%{config: %Config{scenario: :tool_recovery}} = context, observations) do
    expectation = context.proposal.selection
    assertions = stored_assessment(context, observations)

    recovery =
      case Basic.capture(context, observations) do
        {:ok, capture} ->
          {:ok, assertion} =
            Recovery.assess(
              capture,
              expectation.target,
              expectation.arguments,
              expectation.family
            )

          assertion

        _ ->
          {:ok, assertion} =
            Assertion.new("native_tool_recovery", :inconclusive, [])

          assertion
      end

    assertions ++ [recovery]
  end

  def assess(%{config: %Config{scenario: :evidence}} = context, observations),
    do: stored_assessment(context, observations)

  def assess(context, observations),
    do: Basic.assess(context, observations, :claude_managed_agents)

  defp stored_assessment(context, observations) do
    stored =
      case Basic.capture(context, observations) do
        {:ok, capture} ->
          sources =
            Enum.filter(capture.sources, fn source ->
              source.id != "native" and source.kind in [:claude_session, :claude_thread]
            end)

          StoredEvidence.assess(sources, capture.records)

        _ ->
          StoredEvidence.assess([], [])
      end

    Basic.assess(context, observations, :claude_managed_agents) ++ [stored]
  end
end
