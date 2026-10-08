defmodule ReqManagedAgents.Client do
  @moduledoc """
  Compatibility control-plane HTTP client for Claude Managed Agents (agents, sessions,
  events) over `Req`. The long-lived SSE event stream lives in
  `ReqManagedAgents.Stream`.

  Build one with `new/1`; pass it as the first argument to every call. All
  requests carry the `managed-agents-2026-04-01` beta header.
  """
  @behaviour ReqManagedAgents.Client.Behaviour

  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Client, as: CanonicalClient

  @base_url "https://api.anthropic.com"
  @beta "managed-agents-2026-04-01"
  @files_beta "files-api-2025-04-14"
  @anthropic_version "2023-06-01"

  # api_key must never appear in inspect output: a KeyError from missing
  # Session opts prints the whole opts list (client included), as do crash
  # reports.
  @derive {Inspect, except: [:api_key]}
  defstruct [
    :api_key,
    base_url: @base_url,
    beta: @beta,
    files_beta: @files_beta,
    anthropic_version: @anthropic_version,
    receive_timeout: 60_000,
    req_options: [],
    profile: :anthropic
  ]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          beta: String.t(),
          files_beta: String.t(),
          anthropic_version: String.t(),
          receive_timeout: timeout(),
          req_options: keyword(),
          profile: atom()
        }

  @doc "Build a legacy client. See `ReqManagedAgents.Providers.ClaudeManagedAgents.Client.new/1`."
  @spec new(keyword()) :: t()
  def new(opts \\ []),
    do:
      struct!(
        __MODULE__,
        Map.from_struct(CanonicalClient.new(opts))
      )

  @doc false
  defdelegate headers(client), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client
  @impl true
  defdelegate create_agent(client, arg1),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @impl true
  defdelegate get_agent(client, arg1), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client
  @impl true
  defdelegate update_agent(client, arg1, arg2),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @doc false
  defdelegate list_agents(client), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client
  @impl true
  defdelegate list_agents(client, arg1), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client
  @impl true
  defdelegate archive_agent(client, arg1),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @impl true
  defdelegate create_environment(client, arg1),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @impl true
  defdelegate get_environment(client, arg1),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @doc false
  defdelegate list_environments(client), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client
  @impl true
  defdelegate list_environments(client, arg1),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @impl true
  defdelegate archive_environment(client, arg1),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @impl true
  defdelegate create_session(client, arg1),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @impl true
  defdelegate get_session(client, arg1), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client
  @doc false
  defdelegate list_sessions(client), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client
  @impl true
  defdelegate list_sessions(client, arg1),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @impl true
  defdelegate delete_session(client, arg1),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @impl true
  defdelegate archive_session(client, arg1),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @impl true
  defdelegate send_events(client, arg1, arg2),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @impl true
  defdelegate send_event(client, arg1, arg2),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @doc false
  defdelegate list_events(client, arg1), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client
  @impl true
  defdelegate list_events(client, arg1, arg2),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @doc false
  defdelegate list_threads(client, session_id), to: CanonicalClient
  @impl true
  defdelegate list_threads(client, session_id, params), to: CanonicalClient

  @doc false
  defdelegate list_thread_events(client, session_id, thread_id), to: CanonicalClient
  @impl true
  defdelegate list_thread_events(client, session_id, thread_id, params), to: CanonicalClient

  @doc false
  defdelegate list_all_events(client, arg1),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @impl true
  defdelegate list_all_events(client, arg1, arg2),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @impl true
  defdelegate upload_file(client, arg1), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client
  @impl true
  defdelegate download_file(client, arg1),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @impl true
  defdelegate attach_file_to_session(client, arg1, arg2),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  @doc false
  defdelegate list_files(client), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client
  @impl true
  defdelegate list_files(client, arg1), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client
  @impl true
  defdelegate delete_file(client, arg1), to: ReqManagedAgents.Providers.ClaudeManagedAgents.Client
end
