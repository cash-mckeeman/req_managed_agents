defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Acceptance do
  @moduledoc "One fresh budgeted CMA session followed by bounded persisted history."
  @behaviour ReqManagedAgents.Acceptance.Scenario
  alias ReqManagedAgents.Acceptance.{Basic, Config, Context, Observation, Proposal}
  alias ReqManagedAgents.Budget
  alias ReqManagedAgents.Evidence.Options
  alias ReqManagedAgents.Providers.ClaudeManagedAgents
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.{Client, History}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.History.Request

  @impl true
  def propose(%Config{provider: :claude_managed_agents, scenario: :basic} = config) do
    with :ok <- validate(config), do: Proposal.new(config)
  end

  def propose(_), do: {:error, :unsupported_scenario}

  @doc false
  @spec validate(Config.t()) :: :ok | {:error, :invalid_provider_config}
  def validate(config) do
    if resource?(config.resource) and inputs?(config.inputs) and config.bounds.calls == 1,
      do: :ok,
      else: {:error, :invalid_provider_config}
  end

  defp resource?(%{"reference" => agent, "environment_id" => environment} = resource)
       when is_binary(agent) and is_binary(environment),
       do: map_size(resource) == 2 and String.trim(agent) != "" and String.trim(environment) != ""

  defp resource?(_), do: false

  defp inputs?(
         %{"prompt" => prompt, "max_list_cost_cents" => cents, "history_pages" => pages} = inputs
       )
       when is_binary(prompt) and is_integer(cents) and cents > 0 and is_integer(pages) and
              pages > 0,
       do: map_size(inputs) == 3 and String.trim(prompt) != ""

  defp inputs?(_), do: false

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
      {:ok, observations} -> acquire_history(context, client, observations)
      error -> error
    end
  end

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
  def assess(context, observations),
    do: Basic.assess(context, observations, :claude_managed_agents)
end
