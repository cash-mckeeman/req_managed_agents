defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Federation do
  @moduledoc """
  Anthropic workload identity federation settings for a Claude Managed Agents
  client, and the access-token cache behind them. Build a client with
  `ReqManagedAgents.Providers.ClaudeManagedAgents.Client.new/1`; this module is
  its `:federation` field.

  Identity tokens carry a `jti` and are single use, so every exchange fetches a
  fresh one and exchanges are serialised per credential: a second caller waits
  for the first and then finds the cache filled. For an access token expiring
  at `e`:

    * before `e - 120 s` the cached token is served;
    * from `e - 120 s` to `e - 30 s` a new exchange is attempted, and if it
      fails the cached token keeps serving while retries pause for 10 seconds;
    * from `e - 30 s` the cached token is unusable: exchange or fail.
  """

  alias ReqManagedAgents.Config
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.BearerCredential
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Federation.{Cache, Exchange}

  @advisory_seconds 120
  @mandatory_seconds 30
  @backoff_seconds 10

  defstruct [
    :rule_id,
    :organization_id,
    :service_account_id,
    :workspace_id,
    :identity_token_file,
    :identity_token
  ]

  @type identity_token :: (-> {:ok, String.t()} | {:error, term()})
  @type t :: %__MODULE__{
          rule_id: String.t(),
          organization_id: String.t(),
          service_account_id: String.t() | nil,
          workspace_id: String.t() | nil,
          identity_token_file: String.t() | nil,
          identity_token: identity_token() | nil
        }
  @type reason ::
          :identity_token_unreadable
          | :identity_token_invalid
          | :identity_token_unavailable
          | :exchange_rejected
          | :exchange_failed
          | :exchange_invalid_response
  @type http :: %{
          optional(atom()) => term(),
          base_url: String.t(),
          req_options: keyword(),
          receive_timeout: timeout()
        }

  @doc false
  # `:none` when no federation setting is present; an error when some are
  # present but not enough to exchange.
  @spec from_config(keyword()) ::
          :none | {:ok, t()} | {:error, {:incomplete_federation, [atom()]} | :invalid}
  def from_config(opts) do
    rule = setting(opts, :federation_rule_id, "ANTHROPIC_FEDERATION_RULE_ID")
    org = setting(opts, :organization_id, "ANTHROPIC_ORGANIZATION_ID")
    svc = setting(opts, :service_account_id, "ANTHROPIC_SERVICE_ACCOUNT_ID")
    workspace = setting(opts, :workspace_id, "ANTHROPIC_WORKSPACE_ID")
    file = setting(opts, :identity_token_file, "ANTHROPIC_IDENTITY_TOKEN_FILE")
    fun = Config.resolve(opts, :identity_token)

    cond do
      is_nil(rule) and is_nil(file) and is_nil(fun) ->
        :none

      not is_nil(fun) and not is_function(fun, 0) ->
        {:error, :invalid}

      missing = missing(rule, org, file, fun) ->
        {:error, {:incomplete_federation, missing}}

      true ->
        {:ok,
         %__MODULE__{
           rule_id: rule,
           organization_id: org,
           service_account_id: svc,
           workspace_id: workspace,
           identity_token_file: file,
           identity_token: fun
         }}
    end
  end

  # An exported-but-empty variable counts as unset, as in the official SDKs'
  # advice to unset rather than blank.
  defp setting(opts, key, env) do
    case Config.resolve(opts, key, env) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp missing(rule, org, file, fun) do
    list =
      [
        {:federation_rule_id, rule},
        {:organization_id, org},
        {:identity_token_file, file || fun}
      ]
      |> Enum.filter(fn {_, value} -> is_nil(value) end)
      |> Enum.map(&elem(&1, 0))

    if list == [], do: nil, else: list
  end

  @doc false
  # An access token valid for a request made at `now` (Unix seconds), exchanging
  # or refreshing it as the policy above requires.
  @spec token(t(), http(), integer()) :: {:ok, String.t()} | {:error, reason()}
  def token(%__MODULE__{} = federation, http, now) do
    key = cache_key(federation, http)

    case Cache.fetch(key) do
      {%BearerCredential{} = credential, _retry_at}
      when now < credential.expires_at - @advisory_seconds ->
        {:ok, credential.access_token}

      _ ->
        :global.trans(
          {{__MODULE__, key}, self()},
          fn -> refresh(federation, http, key, now) end,
          [node()]
        )
    end
  end

  # Runs under the per-credential lock.
  defp refresh(federation, http, key, now) do
    entry = Cache.fetch(key)

    case entry do
      {credential, _} when now < credential.expires_at - @advisory_seconds ->
        {:ok, credential.access_token}

      {credential, retry_at}
      when retry_at > now and now < credential.expires_at - @mandatory_seconds ->
        {:ok, credential.access_token}

      _ ->
        exchange(federation, http, key, entry, now)
    end
  end

  defp exchange(federation, http, key, entry, now) do
    case Exchange.run(federation, http, now) do
      {:ok, credential} ->
        Cache.put(key, credential, 0)
        {:ok, credential.access_token}

      {:error, reason} ->
        case entry do
          {credential, _} when now < credential.expires_at - @mandatory_seconds ->
            Cache.put(key, credential, now + @backoff_seconds)
            {:ok, credential.access_token}

          _ ->
            {:error, reason}
        end
    end
  end

  defp cache_key(federation, http) do
    source =
      if federation.identity_token,
        do: {:function, federation.identity_token},
        else: {:file, federation.identity_token_file}

    {http.base_url, federation.rule_id, federation.organization_id, federation.service_account_id,
     federation.workspace_id, source}
  end
end
