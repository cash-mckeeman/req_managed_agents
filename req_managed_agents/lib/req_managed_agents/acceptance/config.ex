defmodule ReqManagedAgents.Acceptance.Config do
  @moduledoc "Validated acceptance configuration bound to its exact input bytes."
  alias ReqManagedAgents.Acceptance.Bounds

  @enforce_keys [
    :provider,
    :scenario,
    :resource,
    :source_revision,
    :retain_until,
    :content,
    :bounds,
    :inputs,
    :digest,
    :raw_bytes
  ]
  defstruct @enforce_keys

  @typedoc "Resource and inputs are provider-verbatim JSON maps validated by the scenario edge."
  @type t :: %__MODULE__{
          provider: :agentcore | :claude_managed_agents,
          scenario: :basic | :evidence | :tool_recovery,
          resource: %{String.t() => Jason.Encoder.t()},
          source_revision: String.t(),
          retain_until: DateTime.t(),
          content: :drop | :retain,
          bounds: Bounds.t(),
          inputs: %{String.t() => Jason.Encoder.t()},
          digest: String.t(),
          raw_bytes: binary()
        }
  @type error ::
          :invalid_config
          | :invalid_schema
          | :invalid_selector
          | :invalid_identity
          | :invalid_retention
          | :invalid_bounds
  @providers %{"agentcore" => :agentcore, "claude-managed-agents" => :claude_managed_agents}
  @scenarios %{"basic" => :basic, "evidence" => :evidence, "tool-recovery" => :tool_recovery}
  @keys ~w(schema_version provider scenario resource source_revision retain_until content bounds inputs)

  @doc "Parse strict version-one JSON; the source revision is declared, not checkout-attested."
  @spec parse(binary()) :: {:ok, t()} | {:error, error()}
  def parse(bytes) when is_binary(bytes) do
    with {:ok, data} when is_map(data) <- Jason.decode(bytes),
         :ok <- schema(data),
         {:ok, provider, scenario} <- selectors(data["provider"], data["scenario"]),
         :ok <- identity(data),
         {:ok, deadline, content} <- retention(data),
         {:ok, limits} <- Bounds.new(data["bounds"]) do
      {:ok,
       %__MODULE__{
         provider: provider,
         scenario: scenario,
         resource: data["resource"],
         source_revision: data["source_revision"],
         retain_until: deadline,
         content: content,
         bounds: limits,
         inputs: data["inputs"],
         digest: digest(bytes),
         raw_bytes: bytes
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_config}
    end
  end

  @doc "Revalidate a configuration, including its raw-byte identity."
  @spec new(t()) :: {:ok, t()} | {:error, error()}
  def new(%__MODULE__{raw_bytes: bytes} = config) when is_binary(bytes) do
    case parse(bytes) do
      {:ok, ^config} -> {:ok, config}
      _ -> {:error, :invalid_config}
    end
  end

  def new(_), do: {:error, :invalid_config}

  @doc "Resolve only the closed public command selectors."
  @spec selectors(term(), term()) ::
          {:ok, :agentcore | :claude_managed_agents, :basic | :evidence | :tool_recovery}
          | {:error, :invalid_selector}
  def selectors(provider, scenario) do
    case {@providers[provider], @scenarios[scenario]} do
      {nil, _} -> {:error, :invalid_selector}
      {_, nil} -> {:error, :invalid_selector}
      {p, s} -> {:ok, p, s}
    end
  end

  defp schema(data) do
    if Enum.sort(Map.keys(data)) == Enum.sort(@keys) and data["schema_version"] == 1,
      do: :ok,
      else: {:error, :invalid_schema}
  end

  defp identity(%{
         "source_revision" => revision,
         "resource" => %{"reference" => reference},
         "inputs" => inputs
       })
       when is_binary(revision) and is_binary(reference) and is_map(inputs) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, revision) and String.trim(reference) != "",
      do: :ok,
      else: {:error, :invalid_identity}
  end

  defp identity(_), do: {:error, :invalid_identity}

  defp retention(%{"retain_until" => deadline, "content" => content}) when is_binary(deadline) do
    with {:ok, date, 0} <- DateTime.from_iso8601(deadline),
         true <- DateTime.compare(date, DateTime.utc_now()) == :gt,
         value when not is_nil(value) <- %{"drop" => :drop, "retain" => :retain}[content] do
      {:ok, date, value}
    else
      _ -> {:error, :invalid_retention}
    end
  end

  defp retention(_), do: {:error, :invalid_retention}

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
