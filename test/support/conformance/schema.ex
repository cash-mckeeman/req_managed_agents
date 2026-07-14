defmodule ReqManagedAgents.Conformance.Schema do
  @moduledoc "Structural validation of a decoded JSON value against a botocore-style shape slice. Not a full JSON-Schema engine — required/type/unknown only."

  @type violation ::
          {:missing, String.t()} | {:type, String.t(), String.t()} | {:unknown, String.t()}

  @spec validate(map(), map()) :: :ok | {:error, [violation()]}
  def validate(value, shape) when is_map(value) and is_map(shape) do
    required = Map.get(shape, "required", [])
    members = Map.get(shape, "members", %{})

    missing = for k <- required, not Map.has_key?(value, k), do: {:missing, k}
    unknown = for {k, _} <- value, not Map.has_key?(members, k), do: {:unknown, k}

    typed =
      for {k, v} <- value, spec = members[k], spec != nil, not type_ok?(v, spec["type"]) do
        {:type, k, spec["type"]}
      end

    case missing ++ typed ++ unknown do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  # A member declared in the shape with no `type` carries no type constraint.
  defp type_ok?(_v, nil), do: true

  defp type_ok?(v, "string"), do: is_binary(v)
  defp type_ok?(v, "blob"), do: is_binary(v)
  defp type_ok?(v, "list"), do: is_list(v)
  # botocore objects are "structure"; treat "map" the same (both decode to a JSON object).
  defp type_ok?(v, "map"), do: is_map(v)
  defp type_ok?(v, "structure"), do: is_map(v)
  defp type_ok?(v, "integer"), do: is_integer(v)
  defp type_ok?(v, "long"), do: is_integer(v)
  defp type_ok?(v, "double"), do: is_number(v)
  defp type_ok?(v, "float"), do: is_number(v)
  defp type_ok?(v, "boolean"), do: is_boolean(v)
  defp type_ok?(v, "timestamp"), do: is_binary(v) or is_number(v)

  # An unmodeled type string is an authoring mistake in OUR shape slice (we write
  # these, not the wire) — surface it as a violation rather than silently passing.
  defp type_ok?(_v, _unknown_type), do: false
end
