defmodule ReqManagedAgents.Client do
  @moduledoc """
  Low-level control-plane HTTP client for Claude Managed Agents (agents, sessions,
  events) over `Req`. The long-lived SSE event stream lives in
  `ReqManagedAgents.Stream`.

  Build one with `new/1`; pass it as the first argument to every call. All
  requests carry the `managed-agents-2026-04-01` beta header.
  """
  @behaviour ReqManagedAgents.Client.Behaviour

  @base_url "https://api.anthropic.com"
  @beta "managed-agents-2026-04-01"
  @anthropic_version "2023-06-01"

  defstruct [
    :api_key,
    base_url: @base_url,
    beta: @beta,
    anthropic_version: @anthropic_version,
    receive_timeout: 60_000,
    req_options: []
  ]

  @type t :: %__MODULE__{}

  @doc """
  Build a client. Resolves `:api_key` from the option, then
  `Application.get_env(:req_managed_agents, :api_key)`, then `ANTHROPIC_API_KEY`.
  Other keys fall back to the same application env, then defaults.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      api_key: opts[:api_key] || env(:api_key) || System.fetch_env!("ANTHROPIC_API_KEY"),
      base_url: opts[:base_url] || env(:base_url) || @base_url,
      beta: opts[:beta] || env(:beta) || @beta,
      anthropic_version:
        opts[:anthropic_version] || env(:anthropic_version) || @anthropic_version,
      receive_timeout: opts[:receive_timeout] || env(:receive_timeout) || 60_000,
      req_options: opts[:req_options] || []
    }
  end

  defp env(key), do: Application.get_env(:req_managed_agents, key)

  @doc false
  def headers(%__MODULE__{} = c) do
    [
      {"x-api-key", c.api_key},
      {"anthropic-version", c.anthropic_version},
      {"anthropic-beta", c.beta},
      {"content-type", "application/json"}
    ]
  end

  # ---- Agents ----------------------------------------------------------------
  @impl true
  def create_agent(c, body), do: post(c, "/v1/agents", body)
  @impl true
  def get_agent(c, id), do: get(c, "/v1/agents/#{id}")
  @impl true
  def update_agent(c, id, body), do: post(c, "/v1/agents/#{id}", body)
  @impl true
  def list_agents(c, params \\ %{}), do: get(c, "/v1/agents", params)

  # ---- Sessions --------------------------------------------------------------
  @impl true
  def create_session(c, body), do: post(c, "/v1/sessions", body)
  @impl true
  def get_session(c, id), do: get(c, "/v1/sessions/#{id}")
  @impl true
  def list_sessions(c, params \\ %{}), do: get(c, "/v1/sessions", params)
  @impl true
  def delete_session(c, id), do: delete(c, "/v1/sessions/#{id}")

  # ---- Events ----------------------------------------------------------------
  @impl true
  def send_events(c, session_id, events) when is_list(events),
    do: post(c, "/v1/sessions/#{session_id}/events", %{events: events})

  @doc "Convenience for a single event."
  def send_event(c, session_id, event) when is_map(event),
    do: send_events(c, session_id, [event])

  @impl true
  def list_events(c, session_id, params \\ %{}),
    do: get(c, "/v1/sessions/#{session_id}/events", params)

  # ---- HTTP primitives -------------------------------------------------------

  defp post(c, path, body), do: c |> req(path) |> Req.post(json: body) |> handle()
  defp get(c, path, params \\ %{}), do: c |> req(path) |> Req.get(params: params) |> handle()
  defp delete(c, path), do: c |> req(path) |> Req.delete() |> handle()

  defp req(c, path) do
    [
      base_url: c.base_url,
      url: path,
      headers: headers(c),
      receive_timeout: c.receive_timeout,
      retry: :transient,
      max_retries: 3
    ]
    |> Req.new()
    |> Req.merge(c.req_options)
  end

  defp handle({:ok, %{status: s, body: body}}) when s in 200..299, do: {:ok, body}
  defp handle({:ok, %{status: s, body: body}}), do: {:error, {:http_error, s, body}}
  defp handle({:error, reason}), do: {:error, reason}
end
