defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Provisioning do
  @moduledoc false

  alias ReqManagedAgents.Agent.Spec
  alias ReqManagedAgents.Environment
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Client
  alias ReqManagedAgents.Provisioner.Runtimes

  @type client :: Client.t() | ReqManagedAgents.Client.t()
  @typedoc "Native Claude JSON request and response payloads."
  @type payload :: map()

  @doc "Create a Claude agent from a native request body."
  @spec create_agent(client(), payload()) :: {:ok, payload()} | {:error, term()}
  def create_agent(client, body), do: Client.create_agent(client, body)

  @doc "List Claude agents."
  @spec list_agents(client()) :: {:ok, payload()} | {:error, term()}
  def list_agents(client), do: Client.list_agents(client, %{})

  @doc "Archive a Claude agent by ID."
  @spec archive_agent(client(), String.t()) :: {:ok, payload()} | {:error, term()}
  def archive_agent(client, id), do: Client.archive_agent(client, id)

  @doc "Create a Claude environment from a native request body."
  @spec create_environment(client(), payload()) :: {:ok, payload()} | {:error, term()}
  def create_environment(client, body), do: Client.create_environment(client, body)

  @doc "List Claude environments."
  @spec list_environments(client()) :: {:ok, payload()} | {:error, term()}
  def list_environments(client), do: Client.list_environments(client, %{})

  @doc "Archive a Claude environment by ID."
  @spec archive_environment(client(), String.t()) :: {:ok, payload()} | {:error, term()}
  def archive_environment(client, id), do: Client.archive_environment(client, id)

  @doc "Render a native agent body using the reconciled provider name."
  @spec agent_body(Spec.t(), String.t()) :: payload()
  def agent_body(%Spec{} = spec, name) do
    %{name: name, model: spec.model_config, system: spec.system_prompt, tools: spec.tools}
  end

  @doc "Render native environment config, merging runtime hosts for limited networking."
  @spec environment_config(Environment.Spec.t()) :: payload()
  def environment_config(%Environment.Spec{runtimes: runtimes, config: config}) do
    networking = config[:networking]

    if runtimes != [] and limited_networking?(networking) do
      merge_runtime_hosts(config, runtimes, networking)
    else
      config
    end
  end

  defp limited_networking?(%{type: type}) when type in [:limited, "limited"], do: true
  defp limited_networking?(%{"type" => type}) when type in [:limited, "limited"], do: true
  defp limited_networking?(_), do: false

  defp merge_runtime_hosts(config, runtimes, networking) do
    required = Runtimes.required_hosts(runtimes)

    existing =
      Map.get(networking, :allowed_hosts) || Map.get(networking, "allowed_hosts") || []

    merged = Enum.uniq(existing ++ required)

    # Write back under the key form the networking map already uses.
    hosts_key = if Map.has_key?(networking, "type"), do: "allowed_hosts", else: :allowed_hosts
    Map.put(config, :networking, Map.put(networking, hosts_key, merged))
  end
end
