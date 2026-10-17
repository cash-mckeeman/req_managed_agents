defmodule ReqManagedAgents.Providers.BedrockAgentCore.InvocationLimit do
  @moduledoc false

  @enforce_keys [:limit, :counter]
  defstruct [:limit, :counter]

  @type t :: %__MODULE__{limit: pos_integer(), counter: :atomics.atomics_ref()}
  @type refusal :: {:error, {:max_invocation_attempts_exceeded, pos_integer()}}

  @spec new(term()) :: {:ok, t() | nil} | {:error, {:invalid_opts, :max_invocation_attempts}}
  def new(nil), do: {:ok, nil}

  def new(limit) when is_integer(limit) and limit > 0,
    do: {:ok, %__MODULE__{limit: limit, counter: :atomics.new(1, signed: false)}}

  def new(_), do: {:error, {:invalid_opts, :max_invocation_attempts}}

  @spec take(t() | nil) :: :ok | refusal()
  def take(nil), do: :ok
  def take(%__MODULE__{} = gate), do: reserve(gate, :atomics.get(gate.counter, 1))

  defp reserve(%__MODULE__{limit: limit}, admitted) when admitted >= limit,
    do: {:error, {:max_invocation_attempts_exceeded, limit}}

  defp reserve(%__MODULE__{counter: counter} = gate, admitted) do
    case :atomics.compare_exchange(counter, 1, admitted, admitted + 1) do
      :ok -> :ok
      current -> reserve(gate, current)
    end
  end
end
