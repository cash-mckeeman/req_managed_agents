defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Federation.Exchange do
  @moduledoc false
  # One RFC 7523 jwt-bearer exchange at POST /v1/oauth/token. Failures return
  # a bare reason: the identity token, the access token and the response body
  # never appear in an error.
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.BearerCredential
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Federation

  @grant_type "urn:ietf:params:oauth:grant-type:jwt-bearer"
  # Anthropic rejects assertions above 16 KiB.
  @jwt_limit 16_384

  @spec run(Federation.t(), Federation.http(), integer()) ::
          {:ok, BearerCredential.t()} | {:error, Federation.reason()}
  def run(%Federation{} = federation, http, now) do
    with {:ok, jwt} <- identity_token(federation),
         {:ok, wire} <- post(federation, http, jwt) do
      credential(wire, now)
    end
  end

  # A fresh token for every exchange: the file is reread, the function called.
  defp identity_token(%Federation{identity_token: fun}) when is_function(fun, 0) do
    result =
      try do
        fun.()
      rescue
        _ -> :error
      catch
        _, _ -> :error
      end

    case result do
      {:ok, jwt} -> validate(jwt)
      _ -> {:error, :identity_token_unavailable}
    end
  end

  # File.stat follows symlinks: projected-token volumes publish through them.
  defp identity_token(%Federation{identity_token_file: path}) do
    with {:ok, %{type: :regular, size: size}} when size <= @jwt_limit <- File.stat(path),
         {:ok, bytes} <- File.read(path) do
      validate(bytes)
    else
      {:ok, _} -> {:error, :identity_token_invalid}
      {:error, _} -> {:error, :identity_token_unreadable}
    end
  end

  defp validate(jwt) when is_binary(jwt) do
    jwt = String.trim(jwt)

    if byte_size(jwt) <= @jwt_limit and Regex.match?(~r/\A[\x21-\x7e]+\z/, jwt),
      do: {:ok, jwt},
      else: {:error, :identity_token_invalid}
  end

  defp validate(_), do: {:error, :identity_token_invalid}

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
        receive_timeout: http.receive_timeout,
        json: body
      ]
      |> Req.new()
      |> Req.merge(http.req_options)
      |> Req.merge(retry: false, redirect: false)

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200}} ->
        {:error, :exchange_invalid_response}

      {:ok, %Req.Response{status: status}} when status in 400..499 and status != 429 ->
        {:error, :exchange_rejected}

      _ ->
        {:error, :exchange_failed}
    end
  end

  defp credential(%{"access_token" => token, "expires_in" => seconds}, now)
       when is_integer(seconds) do
    case BearerCredential.new(%{"access_token" => token, "expires_at" => now + seconds}, now) do
      {:ok, credential} -> {:ok, credential}
      {:error, _} -> {:error, :exchange_invalid_response}
    end
  end

  defp credential(_, _), do: {:error, :exchange_invalid_response}
end
