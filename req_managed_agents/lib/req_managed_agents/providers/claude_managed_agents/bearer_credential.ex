defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.BearerCredential do
  @moduledoc false
  @enforce_keys [:access_token, :expires_at]
  @derive {Inspect, except: [:access_token]}
  defstruct [:access_token, :expires_at]
  @type t :: %__MODULE__{access_token: String.t(), expires_at: integer()}
  @type reason :: :unreadable | :invalid_file | :invalid_token | :invalid_expiry | :expired
  @limit 65_536

  @spec read(String.t(), integer()) :: {:ok, t()} | {:error, reason()}
  def read(path, now_seconds) do
    with {:ok, bytes} <- read_regular(path),
         {:ok, wire} when is_map(wire) <- Jason.decode(bytes) do
      new(wire, now_seconds)
    else
      {:error, reason} when reason in [:unreadable, :invalid_file] -> {:error, reason}
      _ -> {:error, :invalid_file}
    end
  end

  @spec new(map(), integer()) :: {:ok, t()} | {:error, reason()}
  def new(wire, now_seconds) do
    # Decoded JSON is the raw file boundary; callers receive only the typed credential.
    token = Map.get(wire, "access_token")
    expiry = Map.get(wire, "expires_at")

    cond do
      not is_binary(token) or not Regex.match?(~r/\A[\x21-\x7e]+\z/, token) ->
        {:error, :invalid_token}

      not is_integer(expiry) ->
        {:error, :invalid_expiry}

      expiry <= now_seconds + 30 ->
        {:error, :expired}

      true ->
        {:ok, %__MODULE__{access_token: token, expires_at: expiry}}
    end
  end

  defp read_regular(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} when size <= @limit -> read_bounded(path)
      {:ok, _} -> {:error, :invalid_file}
      {:error, _} -> {:error, :unreadable}
    end
  end

  defp read_bounded(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          case IO.binread(file, @limit + 1) do
            bytes when is_binary(bytes) and byte_size(bytes) <= @limit -> {:ok, bytes}
            _ -> {:error, :invalid_file}
          end
        after
          File.close(file)
        end

      {:error, _} ->
        {:error, :unreadable}
    end
  end
end
