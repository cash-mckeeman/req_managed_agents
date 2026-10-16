defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Auth do
  @moduledoc false
  alias ReqManagedAgents.Config
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.{BearerCredential, Client}

  defmodule Error do
    @moduledoc false
    @enforce_keys [:reason]
    defexception [:reason]
    @type t :: %__MODULE__{reason: BearerCredential.reason()}
    @impl true
    def message(%__MODULE__{reason: reason}), do: "CMA authentication failed: #{reason}"
  end

  @type source :: {:api_key, String.t()} | {:bearer_file, String.t()}
  @spec resolve(keyword()) :: {:ok, source()} | {:error, :missing | :conflicting | :invalid}
  def resolve(opts) do
    key = Config.resolve(opts, :api_key, "ANTHROPIC_API_KEY")
    path = Config.resolve(opts, :bearer_token_file, "ANTHROPIC_BEARER_TOKEN_FILE")

    case {key, path} do
      {nil, nil} -> {:error, :missing}
      {key, nil} when is_binary(key) and key != "" -> {:ok, {:api_key, key}}
      {nil, path} when is_binary(path) and path != "" -> {:ok, {:bearer_file, path}}
      {key, path} when not is_nil(key) and not is_nil(path) -> {:error, :conflicting}
      _ -> {:error, :invalid}
    end
  end

  @spec headers(Client.t()) ::
          {:ok, [{String.t(), String.t()}]}
          | {:error, {:authentication_error, BearerCredential.reason()}}
  def headers(%Client{bearer_token_file: nil, api_key: key}), do: {:ok, [{"x-api-key", key}]}

  def headers(%Client{bearer_token_file: path}) do
    case BearerCredential.read(path, System.system_time(:second)) do
      {:ok, credential} -> {:ok, [{"authorization", "Bearer " <> credential.access_token}]}
      {:error, reason} -> {:error, {:authentication_error, reason}}
    end
  end

  @spec attach(Req.Request.t(), Client.t()) :: Req.Request.t()
  def attach(request, client) do
    request =
      if client.bearer_token_file, do: Req.merge(request, redirect: false), else: request

    # Authenticate at dispatch so retries reread rotated credentials.
    Req.Request.append_request_steps(request,
      rma_auth: &wrap_adapter(&1, client, &1.adapter)
    )
  end

  defp wrap_adapter(request, client, __MODULE__) do
    Req.Request.put_private(request, :rma_auth_client, client)
  end

  defp wrap_adapter(request, client, adapter) when is_atom(adapter) do
    request
    |> Req.Request.put_private(:rma_auth_client, client)
    |> Req.Request.put_private(:rma_auth_adapter, adapter)
    |> Map.put(:adapter, __MODULE__)
  end

  defp wrap_adapter(request, client, adapter) when is_function(adapter, 1) do
    %{request | adapter: fn request -> authenticate(request, client, adapter) end}
  end

  @doc false
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(request) do
    client = Req.Request.get_private(request, :rma_auth_client)
    adapter = Req.Request.get_private(request, :rma_auth_adapter)
    authenticate(request, client, adapter)
  end

  defp authenticate(request, client, adapter) do
    case headers(client) do
      {:ok, headers} ->
        request =
          request
          |> Req.Request.delete_header("authorization")
          |> Req.Request.delete_header("x-api-key")
          |> Req.Request.put_headers(headers)

        run_adapter(request, adapter)

      {:error, {:authentication_error, reason}} ->
        Req.Request.halt(request, %Error{reason: reason})
    end
  end

  defp run_adapter(request, adapter) when is_atom(adapter), do: adapter.run(request)
  defp run_adapter(request, adapter) when is_function(adapter, 1), do: adapter.(request)

  @spec result({:ok, term()} | {:error, term()}) :: {:ok, term()} | {:error, term()}
  def result({:error, %Error{reason: reason}}), do: {:error, {:authentication_error, reason}}
  def result(other), do: other
end
