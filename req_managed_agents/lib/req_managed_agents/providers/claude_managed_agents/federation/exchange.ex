defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Federation.Exchange do
  @moduledoc false
  # One RFC 7523 jwt-bearer exchange at POST /v1/oauth/token. A failure returns
  # a reason category and, for HTTP failures, the status and Anthropic's
  # request id: the identity token, the access token and the response body
  # never appear in an error.
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.BearerCredential
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Federation

  @grant_type "urn:ietf:params:oauth:grant-type:jwt-bearer"
  # Anthropic rejects assertions above 16 KiB.
  @jwt_limit 16_384

  @doc """
  Telemetry: `[:req_managed_agents, :federation, :exchange, :start | :stop | :exception]`
  (a `:telemetry.span/3`). The stop metadata is `%{result: :ok | reason_category}`;
  no identifier or token is attached.
  """
  @spec run(Federation.t(), Federation.http(), integer()) ::
          {:ok, BearerCredential.t()} | {:error, Federation.reason()}
  def run(%Federation{} = federation, http, now) do
    :telemetry.span([:req_managed_agents, :federation, :exchange], %{}, fn ->
      result = exchange(federation, http, now)
      {result, %{result: outcome(result)}}
    end)
  end

  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, {category, _detail}}), do: category
  defp outcome({:error, category}), do: category

  defp exchange(federation, http, now) do
    with {:ok, jwt} <- identity_token(federation),
         {:ok, wire, detail} <- post(federation, http, jwt) do
      credential(wire, now, detail)
    end
  end

  # A new token for every exchange: the file is reread, the function called.
  # The function runs in its own process so a hung one cannot hold the caller.
  defp identity_token(%Federation{identity_token: fun} = federation) when is_function(fun, 0) do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          _ -> :error
        catch
          _, _ -> :error
        end
      end)

    case Task.yield(task, federation.identity_token_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, jwt}} when is_binary(jwt) and byte_size(jwt) <= @jwt_limit -> validate(jwt)
      {:ok, {:ok, _}} -> {:error, :identity_token_invalid}
      {:ok, _} -> {:error, :identity_token_unavailable}
      {:exit, _} -> {:error, :identity_token_unavailable}
      nil -> {:error, :identity_token_timeout}
    end
  end

  # File.stat follows symlinks: projected-token volumes publish through them.
  # The read is bounded, so an oversized file is never held in memory.
  defp identity_token(%Federation{identity_token_file: path}) do
    with {:ok, %{type: :regular}} <- File.stat(path),
         {:ok, bytes} <- read_bounded(path) do
      validate(bytes)
    else
      {:ok, _} -> {:error, :identity_token_invalid}
      {:error, :too_large} -> {:error, :identity_token_invalid}
      {:error, _} -> {:error, :identity_token_unreadable}
    end
  end

  defp read_bounded(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(file, @jwt_limit + 1) do
          bytes when is_binary(bytes) and byte_size(bytes) <= @jwt_limit -> {:ok, bytes}
          bytes when is_binary(bytes) -> {:error, :too_large}
          _ -> {:error, :unreadable}
        end
      after
        File.close(file)
      end
    end
  end

  defp validate(jwt) when is_binary(jwt) do
    jwt = String.trim(jwt)

    if Regex.match?(~r/\A[\x21-\x7e]+\z/, jwt),
      do: {:ok, jwt},
      else: {:error, :identity_token_invalid}
  end

  defp post(federation, http, jwt) do
    body =
      Map.reject(
        %{
          grant_type: @grant_type,
          assertion: jwt,
          federation_rule_id: federation.rule_id,
          organization_id: federation.organization_id,
          service_account_id: federation.service_account_id,
          workspace_id: federation.workspace_id
        },
        fn {_, value} -> is_nil(value) end
      )

    # Neither retried nor redirected: the assertion is single use.
    request =
      [
        method: :post,
        base_url: http.base_url,
        url: "/v1/oauth/token",
        receive_timeout: federation.receive_timeout,
        json: body
      ]
      |> Req.new()
      |> Req.merge(http.req_options)
      |> Req.merge(retry: false, redirect: false)

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body} = response} when is_map(body) ->
        {:ok, body, detail(response)}

      {:ok, %Req.Response{status: 200} = response} ->
        {:error, {:exchange_invalid_response, detail(response)}}

      {:ok, %Req.Response{status: status} = response} when status in 400..499 and status != 429 ->
        {:error, {:exchange_rejected, detail(response)}}

      {:ok, %Req.Response{} = response} ->
        {:error, {:exchange_failed, detail(response)}}

      {:error, _} ->
        {:error, {:exchange_failed, %{status: nil, request_id: nil}}}
    end
  end

  # Only the status and the request id (to find the attempt in the Console's
  # authentication history). The id is shown in errors, so it is restricted
  # to the characters of an identifier.
  defp detail(%Req.Response{status: status} = response) do
    request_id =
      case Req.Response.get_header(response, "request-id") do
        [id | _] -> if Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, id), do: id
        _ -> nil
      end

    %{status: status, request_id: request_id}
  end

  defp credential(%{"access_token" => token, "expires_in" => seconds}, now, detail)
       when is_integer(seconds) do
    case BearerCredential.new(%{"access_token" => token, "expires_at" => now + seconds}, now) do
      {:ok, credential} -> {:ok, credential}
      {:error, _} -> {:error, {:exchange_invalid_response, detail}}
    end
  end

  defp credential(_, _, detail), do: {:error, {:exchange_invalid_response, detail}}
end
