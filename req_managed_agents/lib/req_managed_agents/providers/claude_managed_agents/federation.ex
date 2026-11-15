defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Federation do
  @moduledoc """
  Anthropic workload identity federation settings for a Claude Managed Agents
  client, and the access-token cache behind them. Build a client with
  `ReqManagedAgents.Providers.ClaudeManagedAgents.Client.new/1`; this module is
  its `:federation` field.

  Identity tokens carry a `jti` and are single use, so every exchange obtains a
  new one and only one exchange per credential runs at a time. Only the caller
  that performs a refresh waits for it. Every other caller holding a usable cached
  token is served it at once, while another process refreshes and during the retry
  pause after a failed refresh. A caller with no usable token waits at most
  `:exchange_timeout`. For an access token expiring at `e`:

    * before `e - 120 s` the cached token is served;
    * from `e - 120 s` to `e - 30 s` one caller exchanges and the others keep
      the cached token; if the exchange fails the cached token keeps serving
      while retries pause for 10 seconds;
    * from `e - 30 s` the cached token is unusable: exchange or fail.

  The 120 s and 30 s margins shrink to half and a quarter of the token's
  lifetime when that is shorter (a 60 s token refreshes from 30 s before expiry).

  The identity-token function is given `:identity_token_timeout` (10 s), and the
  exchange request `:exchange_connect_timeout` (5 s) and `:exchange_receive_timeout`
  (10 s); none uses the client's `:receive_timeout`. One refresh therefore takes at
  most about 25 s, and the `:exchange_timeout` default (30 s) covers it, so a
  waiter outlasts a holder that succeeds. When raising one of the three timeouts,
  raise `:exchange_timeout` to at least their sum.

  Tokens are cached per node, keyed by the settings and the identity-token
  source (the file path, the function, or `:cache_key` when given). Each new
  key is a separate exchange that spends a single-use identity token. Entries
  whose token has expired are dropped whenever a new entry is written.
  """

  alias ReqManagedAgents.Config
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Federation.{Cache, Cache.Entry, Exchange}

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
    exchange_timeout: 30_000,
    identity_token_timeout: 10_000,
    connect_timeout: 5_000,
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
          connect_timeout: pos_integer(),
          receive_timeout: pos_integer()
        }
  @typedoc """
  What is known of a failed exchange's response: the HTTP status (`nil` when there was
  no response) and Anthropic's `request-id` header, never the body.
  """
  @type http_detail :: %{status: integer() | nil, request_id: String.t() | nil}
  @type reason ::
          :identity_token_unreadable
          | :identity_token_invalid
          | :identity_token_unavailable
          | :identity_token_timeout
          | :exchange_timeout
          | {:exchange_rejected | :exchange_failed | :exchange_invalid_response, http_detail()}
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
    defaults = %__MODULE__{}
    exchange_timeout = Config.resolve(opts, :exchange_timeout, nil, defaults.exchange_timeout)

    identity_timeout =
      Config.resolve(opts, :identity_token_timeout, nil, defaults.identity_token_timeout)

    connect_timeout =
      Config.resolve(opts, :exchange_connect_timeout, nil, defaults.connect_timeout)

    receive_timeout =
      Config.resolve(opts, :exchange_receive_timeout, nil, defaults.receive_timeout)

    # The rule id switches federation on, so `federation_rule_id: nil` turns it off.
    cond do
      is_nil(rule) ->
        :none

      not is_nil(fun) and not is_function(fun, 0) ->
        {:error, :invalid}

      not Enum.all?(
        [exchange_timeout, identity_timeout, connect_timeout, receive_timeout],
        &pos_integer?/1
      ) ->
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
           connect_timeout: connect_timeout,
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
      paused?(entry, now) -> paused(entry, now)
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

  # Runs under the per-credential lock, with the clock and the entry read again.
  # Both re-reads are needed: the caller decided to refresh from a snapshot taken
  # before it won the lock, and the previous holder may have finished in between,
  # either with a fresh token (an exchange now would spend a second single-use
  # identity token for nothing) or with a failure whose pause is running (an
  # exchange now would defeat the pause).
  defp refresh(federation, http, key, clock) do
    now = now(clock)
    entry = Cache.fetch(key)

    cond do
      fresh?(entry, now) -> cached(entry)
      paused?(entry, now) -> paused(entry, now)
      true -> exchange(federation, http, key, entry, now, clock)
    end
  end

  defp exchange(federation, http, key, entry, now, clock) do
    result = Exchange.run(federation, http, now)

    # The exchange can take as long as its timeouts. The token's lifetime counts
    # from `now` (the conservative reading), but the pause and the serve decision
    # below must count from when the exchange ended.
    ended = now(clock)

    case result do
      {:ok, credential} ->
        Cache.put(key, %Entry{credential: credential, issued_at: now}, ended)
        {:ok, credential.access_token}

      {:error, reason} ->
        # The failure is shared: until `retry_at`, callers with no usable token
        # get this reason without an exchange or a new identity token.
        failed = %Entry{
          credential: entry && entry.credential,
          issued_at: entry && entry.issued_at,
          retry_at: ended + @backoff_seconds,
          failure: reason
        }

        Cache.put(key, failed, ended)
        if usable?(failed, ended), do: cached(failed), else: {:error, reason}
    end
  end

  defp now(clock) when is_function(clock, 0), do: clock.()
  defp now(clock) when is_integer(clock), do: clock

  defp cached(%Entry{credential: credential}), do: {:ok, credential.access_token}

  defp fresh?(%Entry{credential: nil}, _), do: false
  defp fresh?(%Entry{credential: c} = entry, now), do: now < c.expires_at - advisory(entry)
  defp fresh?(nil, _), do: false

  defp usable?(%Entry{credential: nil}, _), do: false
  defp usable?(%Entry{credential: c} = entry, now), do: now < c.expires_at - mandatory(entry)
  defp usable?(nil, _), do: false

  # Short tokens scale the windows to their lifetime, so one of 60 s is not
  # refreshed on every call.
  defp advisory(entry), do: min(@advisory_seconds, div(lifetime(entry), 2))
  defp mandatory(entry), do: min(@mandatory_seconds, div(lifetime(entry), 4))
  defp lifetime(%Entry{credential: c, issued_at: issued}), do: c.expires_at - issued

  defp paused?(%Entry{retry_at: retry_at}, now), do: retry_at > now
  defp paused?(nil, _), do: false

  # Inside a pause: the cached token if usable, otherwise the shared failure.
  defp paused(%Entry{failure: failure} = entry, now),
    do: if(usable?(entry, now), do: cached(entry), else: {:error, failure})

  # One cache entry per credential. Without `:cache_key` the identity-token
  # source identifies it: closures from the same code with equal captured values
  # are equal and share an entry, closures capturing different values do not.
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
