defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Auth do
  @moduledoc false
  alias ReqManagedAgents.Config
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.{BearerCredential, Client, Federation}

  defmodule Error do
    @moduledoc false
    @enforce_keys [:reason]
    defexception [:reason]
    @type t :: %__MODULE__{reason: ReqManagedAgents.Providers.ClaudeManagedAgents.Auth.reason()}
    @impl true
    def message(%__MODULE__{reason: reason}), do: "CMA authentication failed: #{reason}"
  end

  @type reason :: BearerCredential.reason() | Federation.reason()
  @type source ::
          {:api_key, String.t()} | {:bearer_file, String.t()} | {:federation, Federation.t()}
  @type resolve_error ::
          :missing
          | :invalid
          | {:conflicting, [:api_key | :bearer_token_file | :federation]}
          | {:incomplete_federation, [atom()]}

  @doc false
  # Exactly one source may be configured. Federation counts as configured as
  # soon as any of its identifying settings is present, so a leftover API key
  # never silently wins over it.
  @spec resolve(keyword()) :: {:ok, source()} | {:error, resolve_error()}
  def resolve(opts) do
    key = Config.resolve(opts, :api_key, "ANTHROPIC_API_KEY")
    path = Config.resolve(opts, :bearer_token_file, "ANTHROPIC_BEARER_TOKEN_FILE")
    federation = Federation.from_config(opts)

    names =
      for {name, set?} <- [
            api_key: key != nil,
            bearer_token_file: path != nil,
            federation: federation != :none
          ],
          set?,
          do: name

    select(names, key, path, federation)
  end

  defp select([], _, _, _), do: {:error, :missing}
  defp select([:api_key], key, _, _) when is_binary(key) and key != "", do: {:ok, {:api_key, key}}

  defp select([:bearer_token_file], _, path, _) when is_binary(path) and path != "",
    do: {:ok, {:bearer_file, path}}

  defp select([:federation], _, _, {:ok, federation}), do: {:ok, {:federation, federation}}
  defp select([:federation], _, _, {:error, error}), do: {:error, error}
  defp select([_, _ | _] = names, _, _, _), do: {:error, {:conflicting, names}}
  defp select(_, _, _, _), do: {:error, :invalid}

  @doc false
  @spec describe(resolve_error()) :: String.t()
  def describe({:conflicting, names}) do
    hints = Enum.map_join(names, " or ", &"`#{disable_option(&1)}: nil`")

    federation =
      if :federation in names,
        do:
          " Federation is switched on by ANTHROPIC_FEDERATION_RULE_ID (option :federation_rule_id);" <>
            " to drop it, unset the variable (`unset ANTHROPIC_FEDERATION_RULE_ID`).",
        else: ""

    "more than one credential source is configured (#{Enum.join(names, ", ")}); select exactly one." <>
      " Pass #{hints} to Client.new, or unset the variable behind the one you do not want." <>
      federation
  end

  def describe({:incomplete_federation, missing}),
    do: "federation is missing #{Enum.join(missing, ", ")}"

  def describe(reason), do: to_string(reason)

  defp disable_option(:federation), do: :federation_rule_id
  defp disable_option(name), do: name

  @doc false
  # True when a built client carries exactly one usable credential source.
  @spec valid?(Client.t()) :: boolean()
  def valid?(%Client{} = client) do
    case {client.api_key, client.bearer_token_file, client.federation} do
      {key, nil, nil} -> is_binary(key) and key != ""
      {nil, path, nil} -> is_binary(path) and path != ""
      {nil, nil, %Federation{}} -> true
      _ -> false
    end
  end

  @spec headers(Client.t()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, {:authentication_error, reason()}}
  def headers(%Client{federation: %Federation{} = federation} = client) do
    case Federation.token(federation, client, fn -> System.system_time(:second) end) do
      {:ok, token} -> {:ok, [{"authorization", "Bearer " <> token}]}
      {:error, reason} -> {:error, {:authentication_error, reason}}
    end
  end

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
      if client.bearer_token_file || client.federation,
        do: Req.merge(request, redirect: false),
        else: request

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
