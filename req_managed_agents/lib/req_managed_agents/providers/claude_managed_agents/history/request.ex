defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.History.Request do
  @moduledoc "Validated inputs for bounded Claude history retrieval."
  alias ReqManagedAgents.Evidence.{Capture, Error, Options}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.{Auth, Client}

  @enforce_keys [:client, :options]
  defstruct [:client, :options, :prior]
  @type t :: %__MODULE__{client: Client.t(), options: Options.t(), prior: Capture.t() | nil}

  @doc """
  Accepts a canonical or legacy Claude `:client`, `:options` (an Options struct or keyword list),
  and optional `:prior` capture. Prior evidence must belong to Claude; fetch
  additionally requires its session identity to match. Content defaults to drop
  for both prior and newly retrieved records. Authentication accepts the client's
  selected API-key or bearer-file source; credential files are read only at dispatch.
  """
  @spec new(keyword() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = input) do
    input
    |> Map.from_struct()
    |> Map.to_list()
    |> new()
  end

  def new(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:client, :options, :prior])),
         true <- length(opts) == length(Enum.uniq(Keyword.keys(opts))),
         %Client{} = client <- canonical_client(Keyword.get(opts, :client)),
         true <- valid_client?(client),
         {:ok, options} <- Options.new(Keyword.get(opts, :options, [])),
         {:ok, prior} <- prior(Keyword.get(opts, :prior)) do
      {:ok, %__MODULE__{client: client, options: options, prior: prior}}
    else
      _ -> Error.error(:invalid_options)
    end
  end

  def new(_), do: Error.error(:invalid_options)

  defp canonical_client(%Client{} = client), do: client

  defp canonical_client(%ReqManagedAgents.Client{} = client),
    do: struct!(Client, Map.from_struct(client))

  defp canonical_client(_), do: nil

  defp valid_client?(%Client{} = client) do
    valid_auth?(client) and is_binary(client.base_url) and
      is_binary(client.beta) and is_binary(client.anthropic_version) and
      Keyword.keyword?(client.req_options) and
      (client.receive_timeout == :infinity or
         (is_integer(client.receive_timeout) and client.receive_timeout > 0))
  end

  defp valid_auth?(client) do
    match?(
      {:ok, _},
      Auth.resolve(api_key: client.api_key, bearer_token_file: client.bearer_token_file)
    )
  end

  defp prior(nil), do: {:ok, nil}
  defp prior(%Capture{provider: :managed} = capture), do: Capture.parse(capture)
  defp prior(_), do: Error.error(:invalid_input)
end
