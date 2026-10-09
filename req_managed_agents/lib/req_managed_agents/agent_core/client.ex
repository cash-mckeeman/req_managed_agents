defmodule ReqManagedAgents.AgentCore.Client do
  @moduledoc """
  Compatibility client for `ReqManagedAgents.Providers.BedrockAgentCore.Client`,
  retaining the published client and command-result structs.
  """
  alias ReqManagedAgents.AWS.SigV4
  alias ReqManagedAgents.Providers.BedrockAgentCore.Client, as: CanonicalClient

  # AgentCore has two endpoints that BOTH sign with service name "bedrock-agentcore":
  #   - control plane (CreateHarness/GetHarness/DeleteHarness, credential providers)
  #     → host bedrock-agentcore-control.<region>.amazonaws.com
  #   - data plane (InvokeHarness) → host bedrock-agentcore.<region>.amazonaws.com
  @default_base "https://bedrock-agentcore.us-east-1.amazonaws.com"
  @default_control_base "https://bedrock-agentcore-control.us-east-1.amazonaws.com"
  @default_receive_timeout 600_000

  # credentials (secret key + session token) must never appear in inspect
  # output — see the equivalent guard on ReqManagedAgents.Client.
  @derive {Inspect, except: [:credentials]}
  defstruct [
    :credentials,
    base_url: @default_base,
    control_base_url: @default_control_base,
    service: "bedrock-agentcore",
    receive_timeout: @default_receive_timeout,
    req_options: []
  ]

  @type t :: %__MODULE__{
          credentials: SigV4.creds(),
          base_url: String.t(),
          control_base_url: String.t(),
          service: String.t(),
          receive_timeout: timeout(),
          req_options: keyword()
        }

  @spec new(keyword()) :: t()
  @doc "Build a client with the published AgentCore client struct."
  def new(opts \\ []), do: struct!(__MODULE__, Map.from_struct(CanonicalClient.new(opts)))

  @spec create_harness(
          t() | CanonicalClient.t(),
          ReqManagedAgents.Providers.BedrockAgentCore.HarnessSpec.t() | map()
        ) :: {:ok, map()} | {:error, term()}
  def create_harness(c, spec), do: CanonicalClient.create_harness(c, spec)
  @spec control_plane_attempts(:get | :post | :delete) :: pos_integer()
  def control_plane_attempts(method), do: CanonicalClient.control_plane_attempts(method)
  @spec get_harness(t() | CanonicalClient.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_harness(c, id), do: CanonicalClient.get_harness(c, id)
  @spec list_harnesses(t() | CanonicalClient.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_harnesses(c, opts \\ []), do: CanonicalClient.list_harnesses(c, opts)

  @spec get_harness_endpoint(t() | CanonicalClient.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_harness_endpoint(c, id, endpoint),
    do: CanonicalClient.get_harness_endpoint(c, id, endpoint)

  @spec delete_harness(t() | CanonicalClient.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_harness(c, id), do: CanonicalClient.delete_harness(c, id)

  @spec create_api_key_credential_provider(t() | CanonicalClient.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def create_api_key_credential_provider(c, spec),
    do: CanonicalClient.create_api_key_credential_provider(c, spec)

  @spec invoke_harness(t() | CanonicalClient.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def invoke_harness(c, inv), do: CanonicalClient.invoke_harness(c, inv)

  @spec invoke_agent_runtime_command(t() | CanonicalClient.t(), map()) ::
          {:ok, ReqManagedAgents.AgentCore.CommandResult.t()} | {:error, term()}
  def invoke_agent_runtime_command(client, invocation) do
    case CanonicalClient.invoke_agent_runtime_command(client, invocation) do
      {:ok, %ReqManagedAgents.Providers.BedrockAgentCore.CommandResult{} = result} ->
        {:ok, struct!(ReqManagedAgents.AgentCore.CommandResult, Map.from_struct(result))}

      error ->
        error
    end
  end
end
