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
  @files_beta "files-api-2025-04-14"
  @anthropic_version "2023-06-01"

  defstruct [
    :api_key,
    base_url: @base_url,
    beta: @beta,
    files_beta: @files_beta,
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
      files_beta: opts[:files_beta] || env(:files_beta) || @files_beta,
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

  # Files endpoints use their own beta header (no JSON content-type — multipart sets its own).
  defp file_headers(c, beta) do
    [
      {"x-api-key", c.api_key},
      {"anthropic-version", c.anthropic_version},
      {"anthropic-beta", beta}
    ]
  end

  defp file_req(c, path, headers, extra) do
    ([base_url: c.base_url, url: path, headers: headers, receive_timeout: c.receive_timeout] ++
       extra)
    |> Req.new()
    |> Req.merge(c.req_options)
  end

  defp file_part(path) when is_binary(path), do: File.stream!(path)
  defp file_part({filename, content}) when is_binary(content), do: {content, filename: filename}

  # ---- Agents ----------------------------------------------------------------
  @impl true
  def create_agent(c, body), do: post(c, "/v1/agents", body)
  @impl true
  def get_agent(c, id), do: get(c, "/v1/agents/#{id}")
  @impl true
  def update_agent(c, id, body), do: post(c, "/v1/agents/#{id}", body)
  @impl true
  def list_agents(c, params \\ %{}), do: get(c, "/v1/agents", params)
  @impl true
  def archive_agent(c, id), do: post(c, "/v1/agents/#{id}/archive", %{})

  # ---- Environments ----------------------------------------------------------
  @impl true
  def create_environment(c, body), do: post(c, "/v1/environments", body)
  @impl true
  def get_environment(c, id), do: get(c, "/v1/environments/#{id}")
  @impl true
  def list_environments(c, params \\ %{}), do: get(c, "/v1/environments", params)
  @impl true
  def archive_environment(c, id), do: post(c, "/v1/environments/#{id}/archive", %{})

  # ---- Sessions --------------------------------------------------------------
  @impl true
  def create_session(c, body), do: post(c, "/v1/sessions", body)
  @impl true
  def get_session(c, id), do: get(c, "/v1/sessions/#{id}")
  @impl true
  def list_sessions(c, params \\ %{}), do: get(c, "/v1/sessions", params)
  @impl true
  def delete_session(c, id), do: delete(c, "/v1/sessions/#{id}")
  @impl true
  def archive_session(c, id), do: post(c, "/v1/sessions/#{id}/archive", %{})

  # ---- Events ----------------------------------------------------------------
  @impl true
  def send_events(c, session_id, events) when is_list(events),
    do: post(c, "/v1/sessions/#{session_id}/events", %{events: events})

  @doc "Convenience for a single event."
  @impl true
  def send_event(c, session_id, event) when is_map(event),
    do: send_events(c, session_id, [event])

  @impl true
  def list_events(c, session_id, params \\ %{}),
    do: get(c, "/v1/sessions/#{session_id}/events", params)

  @page_limit 100

  @doc """
  Fetch ALL events for a session, paging via the API's opaque `next_page` cursor
  (limit #{@page_limit}/page). Passes the cursor back as the `page` query param;
  stops when `next_page` is absent/blank, or if a cursor repeats (a guard against
  a pathological server). Returns the flat event list.
  """
  @impl true
  def list_all_events(c, session_id, params \\ %{}) do
    do_list_all(c, session_id, Map.put(params, :limit, @page_limit), [], nil)
  end

  defp do_list_all(c, session_id, params, acc, last_cursor) do
    case list_events(c, session_id, params) do
      {:ok, %{"data" => page} = body} when is_list(page) ->
        acc = acc ++ page

        case body["next_page"] do
          cursor when is_binary(cursor) and cursor != "" and cursor != last_cursor ->
            do_list_all(c, session_id, Map.put(params, :page, cursor), acc, cursor)

          _ ->
            {:ok, acc}
        end

      {:ok, _other} ->
        {:ok, acc}

      {:error, _} = err ->
        err
    end
  end

  # ---- Files (separate beta) -------------------------------------------------
  @impl true
  def upload_file(c, %{purpose: purpose, file: file}) do
    span(:post, "/v1/files", fn ->
      c
      |> file_req("/v1/files", file_headers(c, c.files_beta), [])
      |> Req.post(form_multipart: [purpose: purpose, file: file_part(file)])
    end)
  end

  @impl true
  def download_file(c, file_id) do
    combined = "#{c.files_beta},#{c.beta}"

    span(:get, "/v1/files/#{file_id}/content", fn ->
      c
      |> file_req("/v1/files/#{file_id}/content", file_headers(c, combined), decode_body: false)
      |> Req.get()
    end)
  end

  @impl true
  def attach_file_to_session(c, session_id, %{file_id: file_id, mount_path: mount_path}),
    do:
      post(c, "/v1/sessions/#{session_id}/resources", %{
        type: "file",
        file_id: file_id,
        mount_path: mount_path
      })

  # ---- HTTP primitives -------------------------------------------------------

  defp post(c, path, body),
    do: span(:post, path, fn -> c |> req(path) |> Req.post(json: body) end)

  defp get(c, path, params \\ %{}),
    do: span(:get, path, fn -> c |> req(path) |> Req.get(params: params) end)

  defp delete(c, path), do: span(:delete, path, fn -> c |> req(path) |> Req.delete() end)

  defp span(method, path, fun) do
    :telemetry.span([:req_managed_agents, :request], %{method: method, path: path}, fn ->
      result = handle(fun.())
      {result, %{method: method, path: path, status: status_for(result)}}
    end)
  end

  defp status_for({:ok, _}), do: 200
  defp status_for({:error, {:http_error, s, _}}), do: s
  defp status_for(_), do: nil

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
