defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.ToolSchema do
  @moduledoc "Claude Managed Agents custom-tool definitions from NimbleOptions schemas."

  @doc "Wrap the input schema in the provider custom-tool definition."
  @spec to_custom_tool(String.t(), String.t(), keyword()) :: map()
  def to_custom_tool(name, description, schema) do
    %{
      "type" => "custom",
      "name" => name,
      "description" => description,
      "input_schema" => ReqManagedAgents.ToolSchema.input_schema(schema)
    }
  end
end
