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

    # Req retries resume at the adapter, after ordinary request steps have run.
    Req.Request.append_request_steps(request,
      rma_auth: fn request ->
        adapter = request.adapter
        %{request | adapter: fn request -> authenticate(request, client, adapter) end}
      end
    )
  end

  defp authenticate(request, client, adapter) do
    case headers(client) do
      {:ok, headers} ->
        request =
          request
          |> Req.Request.delete_header("authorization")
          |> Req.Request.delete_header("x-api-key")
          |> Req.Request.put_headers(headers)

        adapter.(request)

      {:error, {:authentication_error, reason}} ->
        Req.Request.halt(request, %Error{reason: reason})
    end
  end

  @spec result({:ok, term()} | {:error, term()}) :: {:ok, term()} | {:error, term()}
  def result({:error, %Error{reason: reason}}), do: {:error, {:authentication_error, reason}}
  def result(other), do: other
end
