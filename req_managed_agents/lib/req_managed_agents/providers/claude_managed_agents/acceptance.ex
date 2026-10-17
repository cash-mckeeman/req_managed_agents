defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Acceptance do
  @moduledoc "Fresh bounded CMA acceptance; selected agents and environments are never modified."
  @behaviour ReqManagedAgents.Acceptance.Scenario
  alias ReqManagedAgents.Acceptance.{Basic, Config, Context, Observation, Proposal}
  alias ReqManagedAgents.{Budget, Providers.ClaudeManagedAgents}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.{Client, History}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.History.Request
  alias ReqManagedAgents.Evidence.Options

  @impl true
  def propose(%Config{scenario: :basic, provider: :claude_managed_agents} = config) do
    with :ok <- validate(config), do: Proposal.new(config)
  end

  def propose(_), do: {:error, :unsupported_scenario}

  @doc false
  @spec validate(Config.t()) :: :ok | {:error, :invalid_provider_config}
  def validate(config) do
    resource = config.resource
    inputs = config.inputs

    valid =
      Enum.sort(Map.keys(resource)) == ~w(environment_id reference) and
        Enum.all?(
          [resource["reference"], resource["environment_id"]],
          &(is_binary(&1) and String.trim(&1) != "")
        ) and
        Enum.sort(Map.keys(inputs)) == ~w(history_pages max_list_cost_cents prompt) and
        is_binary(inputs["prompt"]) and String.trim(inputs["prompt"]) != "" and
        Enum.all?(
          [inputs["max_list_cost_cents"], inputs["history_pages"]],
          &(is_integer(&1) and &1 > 0)
        ) and
        config.bounds.calls == 1

    if valid, do: :ok, else: {:error, :invalid_provider_config}
  end

  @impl true
  def run(%Context{} = context) do
    config = context.config
    client = client(context)
    {:ok, budget} = Budget.new(%{max_list_cost_cents: config.inputs["max_list_cost_cents"]})

    opts = [
      client: client,
      agent_id: config.resource["reference"],
      environment_id: config.resource["environment_id"],
      prompt: config.inputs["prompt"],
      budget: budget
    ]

    case Basic.session(context, ClaudeManagedAgents, opts) do
      {:ok, observations} -> history(context, client, observations)
      error -> error
    end
  end

  defp client(context) do
    candidate = context.transport[:client] || Client.new()

    %{
      candidate
      | req_options: Keyword.put(candidate.req_options, :retry, false),
        receive_timeout: context.config.bounds.timeout_ms
    }
  end

  defp history(context, client, observations) do
    with {:ok, prior} <- Basic.capture(context, observations),
         true <- is_binary(prior.session_id),
         {:ok, options} <-
           Options.new(
             max_pages: context.config.inputs["history_pages"],
             max_records: context.config.bounds.records,
             max_bytes: context.config.bounds.bytes,
             timeout_ms: max(context.deadline - System.monotonic_time(:millisecond), 1),
             content: :retain
           ),
         {:ok, request} <- Request.new(client: client, options: options, prior: prior),
         {:ok, capture} <- History.fetch(prior.session_id, request),
         {:ok, observation} <-
           Observation.new(
             "bounded_history",
             :passed,
             Enum.map(capture.records, &(&1.source_id <> ":" <> &1.id))
           ) do
      {:ok, observations ++ [%{observation | capture: capture}]}
    else
      _ ->
        {:ok, observation} = Observation.new("history_unavailable", :failed, [])
        {:error, :history_failed, observations ++ [observation]}
    end
  end

  @impl true
  def assess(context, observations),
    do: Basic.assess(context, observations, :claude_managed_agents)
end
