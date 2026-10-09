defmodule ReqManagedAgents.Evidence.CloudWatchClient do
  @moduledoc """
  Read-only CloudWatch Logs JSON transport using the optional `:ex_aws_auth` signer.
  Credentials or a zero-argument credential resolver must be supplied explicitly;
  this client never resolves credentials from environment, profiles or metadata.
  """
  alias ReqManagedAgents.AWS.SigV4
  alias ReqManagedAgents.Evidence.{Error, Validation}

  @derive {Inspect, except: [:credentials, :transport]}
  @enforce_keys [:region]
  defstruct [:region, :credentials, :transport, timeout_ms: 30_000]
  @typedoc "Caller-supplied credential map at the AWS signing boundary."
  @type credentials :: %{
          required(:access_key_id) => String.t(),
          required(:secret_access_key) => String.t(),
          optional(:security_token) => String.t() | nil
        }
  @type t :: %__MODULE__{
          region: String.t(),
          credentials: credentials() | (-> {:ok, credentials()} | {:error, term()}) | nil,
          transport: (term() -> term()) | nil,
          timeout_ms: pos_integer()
        }
  @type safe_reason :: :unavailable | :invalid_request
  @fields ~w(region credentials transport timeout_ms)a

  @doc "Validates explicit region, credentials/resolver and optional injected Plug transport."
  @spec new(keyword() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = input), do: input |> Map.from_struct() |> Map.to_list() |> new()

  def new(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- length(opts) == length(Enum.uniq(Keyword.keys(opts))),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in @fields)),
         true <- valid_region?(Keyword.get(opts, :region)),
         credentials = Keyword.get(opts, :credentials),
         true <-
           credentials == nil or is_function(credentials, 0) or valid_credentials?(credentials),
         transport = Keyword.get(opts, :transport),
         true <- transport == nil or is_function(transport, 1),
         {:ok, timeout} <- Validation.positive(Keyword.get(opts, :timeout_ms, 30_000)) do
      {:ok,
       %__MODULE__{
         region: opts[:region],
         credentials: credentials,
         transport: transport,
         timeout_ms: timeout
       }}
    else
      _ -> Error.error(:invalid_options)
    end
  end

  def new(_), do: Error.error(:invalid_options)

  @doc false
  @spec valid_region?(term()) :: boolean()
  def valid_region?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-z]{2}(?:-[a-z]+)+-[0-9]+\z/, value)

  @doc "Sends only FilterLogEvents with explicit interval/group and unmask=false; errors omit response bodies."
  @spec filter_log_events(t(), map()) :: {:ok, map()} | {:error, safe_reason()}
  def filter_log_events(%__MODULE__{} = input, request) do
    with {:ok, client} <- new(input),
         true <- valid_request?(request),
         {:ok, credentials} <- resolve(client.credentials) do
      send_request(client, request, Map.put(credentials, :region, client.region))
    else
      false -> {:error, :invalid_request}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp send_request(client, request, credentials) do
    domain =
      if String.starts_with?(client.region, "cn-"), do: "amazonaws.com.cn", else: "amazonaws.com"

    url = "https://logs.#{client.region}.#{domain}/"
    body = Jason.encode!(request)

    headers =
      SigV4.sign_request(:post, url, body,
        credentials: credentials,
        service: "logs",
        headers: [
          {"content-type", "application/x-amz-json-1.1"},
          {"x-amz-target", "Logs_20140328.FilterLogEvents"}
        ]
      )

    options = [
      url: url,
      body: body,
      headers: headers,
      retry: false,
      redirect: false,
      decode_body: false,
      receive_timeout: client.timeout_ms
    ]

    options =
      if client.transport, do: Keyword.put(options, :plug, client.transport), else: options

    case Req.post(options) do
      {:ok, %Req.Response{status: 200, body: body}} -> decode_page(body)
      _ -> {:error, :unavailable}
    end
  end

  defp decode_page(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, page} when is_map(page) -> {:ok, page}
      _ -> {:error, :unavailable}
    end
  end

  defp decode_page(_), do: {:error, :unavailable}

  defp resolve(resolver) when is_function(resolver, 0) do
    case resolver.() do
      {:ok, credentials} -> resolve(credentials)
      _ -> {:error, :unavailable}
    end
  end

  defp resolve(credentials),
    do: if(valid_credentials?(credentials), do: {:ok, credentials}, else: {:error, :unavailable})

  defp valid_credentials?(value) when is_map(value) do
    Enum.all?(
      [:access_key_id, :secret_access_key],
      &(is_binary(Map.get(value, &1)) and Map.get(value, &1) != "")
    ) and
      (Map.get(value, :security_token) == nil or is_binary(Map.get(value, :security_token)))
  end

  defp valid_credentials?(_), do: false

  defp valid_request?(
         %{"logGroupName" => group, "startTime" => from, "endTime" => to, "unmask" => false} =
           request
       ) do
    is_binary(group) and group != "" and is_integer(from) and from >= 0 and is_integer(to) and
      to >= from and
      Enum.all?(
        Map.keys(request),
        &(&1 in ~w(logGroupName startTime endTime unmask nextToken limit))
      ) and
      valid_cursor?(Map.get(request, "nextToken")) and valid_limit?(Map.get(request, "limit"))
  end

  defp valid_request?(_), do: false
  defp valid_cursor?(nil), do: true
  defp valid_cursor?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_limit?(nil), do: true
  defp valid_limit?(value), do: is_integer(value) and value in 1..10_000
end
