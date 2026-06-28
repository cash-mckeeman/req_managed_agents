defmodule ReqManagedAgents.Provisioner do
  @moduledoc """
  Hash-keyed provision cache. `ensure/2` returns a cached `{agent_id, environment_id}`
  for a given agent spec, calling the provided `create_fun` only on a miss. ETS-backed
  (process-independent); persistence is a later seam.
  """
  @table :req_managed_agents_provisions

  @type spec :: %{
          system_prompt: String.t(),
          tools: [map()],
          terminal_tool: String.t() | nil,
          model: String.t()
        }
  @type ref :: %{agent_id: String.t(), environment_id: String.t()}

  @spec ensure(spec(), (spec() -> {:ok, ref()} | {:error, term()})) ::
          {:ok, ref()} | {:error, term()}
  def ensure(spec, create_fun) when is_function(create_fun, 1) do
    table = ensure_table()
    key = hash(spec)

    case :ets.lookup(table, key) do
      [{^key, ref}] ->
        {:ok, ref}

      [] ->
        case create_fun.(spec) do
          {:ok, ref} ->
            :ets.insert(table, {key, ref})
            {:ok, ref}

          {:error, reason} ->
            {:error, {:provision_failed, reason}}
        end
    end
  end

  @doc false
  def reset,
    do: if(:ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table), else: :ok)

  defp hash(spec), do: :crypto.hash(:sha256, :erlang.term_to_binary(spec)) |> Base.encode16()

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _ref -> @table
    end
  end
end
