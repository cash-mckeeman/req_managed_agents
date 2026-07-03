defmodule ReqManagedAgents.Artifacts.ClaudeFiles do
  @moduledoc """
  `ReqManagedAgents.Artifacts` store over the Anthropic Files API, scoped to one
  session. `list` uses the session-scoped file listing (the only way to discover
  server-minted file ids for files the agent wrote); `fetch`/`delete` act on the
  newest record when a name appears more than once (re-runs accumulate);
  `put` uploads and attaches at `opts[:mount_path]` (default `"/data/<name>"`).
  """
  @behaviour ReqManagedAgents.Artifacts

  alias ReqManagedAgents.Artifact

  @doc "Build a store term. `client_mod` is injectable for tests (defaults to the live client)."
  def store(client, session_id, opts \\ []) do
    %{
      client: client,
      session_id: session_id,
      client_mod: opts[:client_mod] || ReqManagedAgents.Client
    }
  end

  @impl true
  def list(store, _opts \\ []) do
    with {:ok, %{"data" => files}} <-
           store.client_mod.list_files(store.client, params: %{scope_id: store.session_id}) do
      {:ok, Enum.map(files, &to_artifact/1)}
    end
  end

  @impl true
  def fetch(store, name, opts \\ []) do
    with {:ok, %{"id" => id}} <- newest(store, name, opts) do
      store.client_mod.download_file(store.client, id)
    end
  end

  @impl true
  def put(store, name, contents, opts \\ []) do
    mount_path = opts[:mount_path] || "/data/" <> name

    with {:ok, %{"id" => file_id}} <-
           store.client_mod.upload_file(store.client, %{purpose: "agent", file: {name, contents}}),
         {:ok, _} <-
           store.client_mod.attach_file_to_session(store.client, store.session_id, %{
             file_id: file_id,
             mount_path: mount_path
           }) do
      :ok
    end
  end

  @impl true
  def delete(store, name, opts \\ []) do
    with {:ok, %{"id" => id}} <- newest(store, name, opts),
         {:ok, _} <- store.client_mod.delete_file(store.client, id) do
      :ok
    end
  end

  defp newest(store, name, _opts) do
    with {:ok, %{"data" => files}} <-
           store.client_mod.list_files(store.client, params: %{scope_id: store.session_id}) do
      files
      |> Enum.filter(&(&1["filename"] == name))
      |> Enum.sort_by(& &1["created_at"], :desc)
      |> case do
        [newest | _] -> {:ok, newest}
        [] -> {:error, :not_found}
      end
    end
  end

  defp to_artifact(file) do
    %Artifact{
      name: file["filename"],
      size: file["size_bytes"],
      ref: file["id"],
      raw: file
    }
  end
end
