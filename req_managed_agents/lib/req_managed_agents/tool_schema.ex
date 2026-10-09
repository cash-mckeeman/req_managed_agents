defmodule ReqManagedAgents.ToolSchema do
  @moduledoc "JSON Schema construction from NimbleOptions tool input schemas."

  @doc "Compatibility entry point for the Claude Managed Agents custom-tool wrapper."
  @spec to_custom_tool(String.t(), String.t(), keyword()) :: map()
  defdelegate to_custom_tool(name, description, schema),
    to: ReqManagedAgents.Providers.ClaudeManagedAgents.ToolSchema

  @doc "Build an object input schema, preserving required fields and property descriptions."
  @spec input_schema(keyword()) :: map()
  def input_schema(jido_schema) do
    props = Map.new(jido_schema, fn {key, spec} -> {to_string(key), property(spec)} end)

    required =
      jido_schema
      |> Enum.filter(fn {_k, spec} -> Keyword.get(spec, :required, false) end)
      |> Enum.map(fn {k, _} -> to_string(k) end)

    %{"type" => "object", "properties" => props, "required" => required}
  end

  defp property(spec) do
    base = %{"type" => json_type(Keyword.get(spec, :type, :string))}

    case Keyword.get(spec, :doc) do
      nil -> base
      doc -> Map.put(base, "description", doc)
    end
  end

  defp json_type(:string), do: "string"
  defp json_type(:integer), do: "integer"
  defp json_type(:float), do: "number"
  defp json_type(:boolean), do: "boolean"
  defp json_type(:map), do: "object"
  defp json_type({:list, _}), do: "array"
  defp json_type(_), do: "string"
end
