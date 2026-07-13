defmodule ReqManagedAgents.Environment.Spec do
  @moduledoc """
  Content-addressed identity of the runtime environment an agent is provisioned
  into — the environment mirror of `ReqManagedAgents.Agent.Spec`. `config` is
  provider-verbatim (opaque; the library never interprets it); `runtimes` is
  typed — the library renders it, so `new/1` validates every runtime through
  `ReqManagedAgents.Provisioner.Runtime.new/1` before it can reach the bootstrap
  renderer.

  `digest/1` folds this identity into the provision content-address at both
  hashing layers (the `Provisioner` cache key and the Bedrock harness name), so
  two provisions of the same `Agent.Spec` into *different* environments no longer
  collide. `name` is excluded from the digest (it is the base, not the identity),
  exactly as in `Agent.Spec.digest/1`.
  """
  alias ReqManagedAgents.Provisioner
  alias ReqManagedAgents.Provisioner.Runtime

  @derive Jason.Encoder
  defstruct [:name, runtimes: [], config: %{}]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          runtimes: [Runtime.t()],
          config: map()
        }

  @doc """
  Coerce a map, an existing `%Spec{}`, or `nil` into a validated environment spec.

  `nil` means "no environment" and is valid (`{:ok, nil}`). A map or struct has
  each runtime validated/coerced via `Runtime.new/1`; any invalid runtime fails
  the whole coercion with `{:error, :invalid_environment_spec}`, so no unvalidated
  runtime can reach the bootstrap renderer. Both atom- and string-keyed maps are
  accepted (mirroring `Agent.Spec.new/1`'s tolerance).
  """
  @spec new(t() | map() | nil) :: {:ok, t() | nil} | {:error, :invalid_environment_spec}
  def new(nil), do: {:ok, nil}

  def new(%__MODULE__{runtimes: runtimes} = spec) do
    with {:ok, runtimes} <- coerce_runtimes(runtimes) do
      {:ok, %{spec | runtimes: runtimes}}
    end
  end

  def new(%{} = m) do
    with {:ok, runtimes} <- coerce_runtimes(fetch(m, :runtimes, [])) do
      {:ok,
       %__MODULE__{
         name: fetch(m, :name, nil),
         runtimes: runtimes,
         config: fetch(m, :config, %{})
       }}
    end
  end

  def new(_other), do: {:error, :invalid_environment_spec}

  @doc """
  Deterministic content-address over the environment's identity fields
  (`{runtimes, config}`, `name` excluded), using the same `Provisioner.hash/1`
  helper as the rest of the provisioner. This is what makes an environment
  content-addressable at both provisioning layers.
  """
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{runtimes: runtimes, config: config}),
    do: Provisioner.hash({runtimes, config})

  defp coerce_runtimes(runtimes) when is_list(runtimes) do
    Enum.reduce_while(runtimes, {:ok, []}, fn r, {:ok, acc} ->
      case Runtime.new(r) do
        {:ok, rt} -> {:cont, {:ok, [rt | acc]}}
        {:error, _} -> {:halt, {:error, :invalid_environment_spec}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp coerce_runtimes(_), do: {:error, :invalid_environment_spec}

  defp fetch(m, key, default),
    do: Map.get(m, key, Map.get(m, Atom.to_string(key), default))
end
