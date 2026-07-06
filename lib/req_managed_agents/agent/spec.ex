defmodule ReqManagedAgents.Agent.Spec do
  @moduledoc """
  A content-addressed agent definition — the managed-entity analogue of an
  environment spec. `name` is the repository base; the digest hashes only the
  identity content (`system_prompt`, `tools`, `terminal_tool`, `model_config`),
  so two identically-defined agents share a digest regardless of their name.
  """
  @enforce_keys [:name, :system_prompt]
  defstruct [:name, :system_prompt, :terminal_tool, :model_config, tools: []]

  @type t :: %__MODULE__{
          name: String.t(),
          system_prompt: String.t(),
          terminal_tool: String.t() | nil,
          model_config: term(),
          tools: [map()]
        }

  @doc "Coerce a map or an existing `%Spec{}` into a validated `%Spec{}`."
  @spec new(t() | map()) :: {:ok, t()} | {:error, :invalid_agent_spec}
  def new(%__MODULE__{} = spec), do: {:ok, spec}

  def new(%{name: name, system_prompt: sys} = m) when is_binary(name) and is_binary(sys) do
    {:ok,
     %__MODULE__{
       name: name,
       system_prompt: sys,
       terminal_tool: Map.get(m, :terminal_tool),
       model_config: Map.get(m, :model_config),
       tools: Map.get(m, :tools, [])
     }}
  end

  def new(_other), do: {:error, :invalid_agent_spec}

  @doc """
  The 8-hex (lowercased) content-address of the agent's identity fields —
  `name` is deliberately excluded (it is the base, not the identity).
  """
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = spec) do
    content = %{
      system_prompt: spec.system_prompt,
      tools: spec.tools,
      terminal_tool: spec.terminal_tool,
      model_config: spec.model_config
    }

    hex8 = content |> ReqManagedAgents.Provisioner.hash() |> binary_part(0, 8)
    String.downcase(hex8)
  end
end
