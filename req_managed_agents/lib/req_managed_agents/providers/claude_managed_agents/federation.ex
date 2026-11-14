defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Federation do
  @moduledoc """
  Anthropic workload identity federation settings for a Claude Managed Agents
  client, and the access-token cache behind them. Build a client with
  `ReqManagedAgents.Providers.ClaudeManagedAgents.Client.new/1`; this module is
  its `:federation` field.

  Identity tokens carry a `jti` and are single use, so every exchange obtains a
  new one and only one exchange per credential runs at a time. A caller who holds
  a usable cached token never waits for it: while another process refreshes, or
  during the retry pause after a failed refresh, the cached token is served. A
  caller with no usable token waits at most `:exchange_timeout` (15 s). For an
  access token expiring at `e`:

    * before `e - 120 s` the cached token is served;
    * from `e - 120 s` to `e - 30 s` one caller exchanges and the others keep
      the cached token; if the exchange fails the cached token keeps serving
      while retries pause for 10 seconds;
    * from `e - 30 s` the cached token is unusable: exchange or fail.

  The identity-token function is given `:identity_token_timeout` (10 s) and the
  exchange request `:exchange_receive_timeout` (10 s); neither uses the client's
  `:receive_timeout`.

  Tokens are cached per node, keyed by the settings and the identity-token
  source (the file path, the function, or `:cache_key` when given). Each new
  key is a separate exchange that spends a single-use identity token. Entries
  whose token has expired are dropped whenever a new entry is written.
  """

  alias ReqManagedAgents.Config
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Federation.{Cache, Exchange}

  @advisory_seconds 120
  @mandatory_seconds 30
  @backoff_seconds 10
  @poll_ms 25

  defstruct [
    :rule_id,
    :organization_id,
    :service_account_id,
    :workspace_id,
    :identity_token_file,
    :identity_token,
    :cache_key,
    exchange_timeout: 15_000,
    identity_token_timeout: 10_000,
    receive_timeout: 10_000
  ]

  @type identity_token :: (-> {:ok, String.t()} | {:error, term()})
  @typedoc """
  `:cache_key` is any term; clients sharing it, and the other settings, share one
  cached access token even when each passes its own `:identity_token` closure.
  """
  @type t :: %__MODULE__{
          rule_id: String.t(),
          organization_id: String.t(),
          service_account_id: String.t() | nil,
          workspace_id: String.t() | nil,
          identity_token_file: String.t() | nil,
          identity_token: identity_token() | nil,
          cache_key: term(),
          exchange_timeout: pos_integer(),
          identity_token_timeout: pos_integer(),
          receive_timeout: pos_integer()
        }
  @type reason ::
          :identity_token_unreadable
          | :identity_token_invalid
          | :identity_token_unavailable
          | :identity_token_timeout
          | :exchange_timeout
          | :exchange_rejected
          | :exchange_failed
          | :exchange_invalid_response
  @type http :: %{optional(atom()) => term(), base_url: String.t(), req_options: keyword()}
  @type clock :: integer() | (-> integer())

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
    cache_key = Config.resolve(opts, :cache_key)
    exchange_timeout = Config.resolve(opts, :exchange_timeout, nil, 15_000)
    identity_timeout = Config.resolve(opts, :identity_token_timeout, nil, 10_000)
    receive_timeout = Config.resolve(opts, :exchange_receive_timeout, nil, 10_000)

    # The rule id switches federation on, so `federation_rule_id: nil` turns it off.
    cond do
      is_nil(rule) ->
        :none

      not is_nil(fun) and not is_function(fun, 0) ->
        {:error, :invalid}

      not Enum.all?([exchange_timeout, identity_timeout, receive_timeout], &pos_integer?/1) ->
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
           identity_token: fun,
           cache_key: cache_key,
           exchange_timeout: exchange_timeout,
           identity_token_timeout: identity_timeout,
           receive_timeout: receive_timeout
         }}
    end
  end

  defp pos_integer?(value), do: is_integer(value) and value > 0

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
  # An access token valid for a request at the time `clock` reports (Unix
  # seconds; an integer is a fixed time), exchanging or refreshing as the
  # policy above requires. Waits at most `exchange_timeout` milliseconds.
  @spec token(t(), http(), clock()) :: {:ok, String.t()} | {:error, reason()}
  def token(%__MODULE__{} = federation, http, clock) do
    key = cache_key(federation, http)
    deadline = System.monotonic_time(:millisecond) + federation.exchange_timeout
    serve(federation, http, key, clock, deadline)
  end

  defp serve(federation, http, key, clock, deadline) do
    now = now(clock)
    entry = Cache.fetch(key)

    cond do
      fresh?(entry, now) -> cached(entry)
      paused?(entry, now) and usable?(entry, now) -> cached(entry)
      true -> locked(federation, http, key, clock, entry, now, deadline)
    end
  end

  # Never waits on the lock: a busy lock serves a usable cached token, and a
  # caller with none polls until the holder finishes or the deadline passes.
  defp locked(federation, http, key, clock, entry, now, deadline) do
    lock = {{__MODULE__, key}, self()}

    cond do
      :global.set_lock(lock, [node()], 0) ->
        try do
          refresh(federation, http, key, clock)
        after
          :global.del_lock(lock, [node()])
        end

      usable?(entry, now) ->
        cached(entry)

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :exchange_timeout}

      true ->
        Process.sleep(@poll_ms)
        serve(federation, http, key, clock, deadline)
    end
  end

  # Runs under the per-credential lock, with the clock read again.
  defp refresh(federation, http, key, clock) do
    now = now(clock)
    entry = Cache.fetch(key)

    cond do
      fresh?(entry, now) -> cached(entry)
      paused?(entry, now) and usable?(entry, now) -> cached(entry)
      true -> exchange(federation, http, key, entry, now)
    end
  end

  defp exchange(federation, http, key, entry, now) do
    case Exchange.run(federation, http, now) do
      {:ok, credential} ->
        Cache.put(key, credential, 0, now)
        {:ok, credential.access_token}

      {:error, reason} ->
        if usable?(entry, now) do
          {credential, _} = entry
          Cache.put(key, credential, now + @backoff_seconds, now)
          {:ok, credential.access_token}
        else
          {:error, reason}
        end
    end
  end

  defp now(clock) when is_function(clock, 0), do: clock.()
  defp now(clock) when is_integer(clock), do: clock

  defp cached({credential, _}), do: {:ok, credential.access_token}

  defp fresh?({credential, _}, now), do: now < credential.expires_at - @advisory_seconds
  defp fresh?(nil, _), do: false

  defp usable?({credential, _}, now), do: now < credential.expires_at - @mandatory_seconds
  defp usable?(nil, _), do: false

  defp paused?({_, retry_at}, now), do: retry_at > now
  defp paused?(nil, _), do: false

  # One cache entry per credential. Without `:cache_key` the identity-token
  # source identifies it, so a fresh closure per client is a fresh entry.
  defp cache_key(federation, http) do
    source =
      cond do
        federation.cache_key != nil -> {:key, federation.cache_key}
        federation.identity_token -> {:function, federation.identity_token}
        true -> {:file, federation.identity_token_file}
      end

    {http.base_url, federation.rule_id, federation.organization_id, federation.service_account_id,
     federation.workspace_id, source}
  end
end
