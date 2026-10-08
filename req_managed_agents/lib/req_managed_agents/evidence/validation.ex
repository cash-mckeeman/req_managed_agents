defmodule ReqManagedAgents.Evidence.Validation do
  @moduledoc false
  alias ReqManagedAgents.Evidence.Error

  def get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  def fields(attrs, specs) when is_map(attrs) do
    Enum.reduce_while(specs, {:ok, %{}}, fn {key, validator, default}, {:ok, values} ->
      case validator.(get(attrs, key, default)) do
        {:ok, value} -> {:cont, {:ok, Map.put(values, key, value)}}
        _ -> {:halt, Error.error(:invalid_input)}
      end
    end)
  end

  def fields(_, _), do: Error.error(:invalid_input)

  def enum(value, lookup) when is_atom(value), do: enum(Atom.to_string(value), lookup)

  def enum(value, lookup) do
    case Map.fetch(lookup, value) do
      {:ok, value} -> {:ok, value}
      :error -> Error.error(:invalid_input)
    end
  end

  def id(value) when is_binary(value) and byte_size(value) > 0 do
    if String.valid?(value) and byte_size(value) <= 1024 and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: Error.error(:invalid_input)
  end

  def id(_), do: Error.error(:invalid_input)

  def safe_id(value) when is_binary(value) do
    if Regex.match?(~r/\A[A-Za-z0-9_.:@-]{1,256}\z/, value) and not String.contains?(value, "://"),
      do: {:ok, value},
      else: Error.error(:invalid_input)
  end

  def safe_id(_), do: Error.error(:invalid_input)

  def optional(nil, _), do: {:ok, nil}
  def optional(value, validator), do: validator.(value)
  def positive(value) when is_integer(value) and value > 0, do: {:ok, value}
  def positive(_), do: Error.error(:invalid_input)
  def nonnegative(value) when is_integer(value) and value >= 0, do: {:ok, value}
  def nonnegative(_), do: Error.error(:invalid_input)
  def integer(value) when is_integer(value), do: {:ok, value}
  def integer(_), do: Error.error(:invalid_input)

  def utc(%DateTime{utc_offset: 0, std_offset: 0} = value), do: {:ok, value}

  def utc(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> Error.error(:invalid_input)
    end
  end

  def utc(_), do: Error.error(:invalid_input)

  def ordered?(from, to), do: DateTime.compare(from, to) != :gt

  def list(values, constructor) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case constructor.(value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  def list(_, _), do: Error.error(:invalid_input)

  def only_keys?(attrs, keys) do
    allowed = [:__struct__ | keys ++ Enum.map(keys, &Atom.to_string/1)]
    Enum.all?(Map.keys(attrs), &(&1 in allowed))
  end

  def json?(value) when is_binary(value), do: String.valid?(value)
  def json?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  def json?(value) when is_list(value), do: Enum.all?(value, &json?/1)

  def json?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, val} -> is_binary(key) and String.valid?(key) and json?(val) end)

  def json?(_), do: false

  def wire(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def wire(value) when is_struct(value), do: value |> Map.from_struct() |> wire()
  def wire(value) when is_map(value), do: Map.new(value, fn {k, v} -> {to_string(k), wire(v)} end)
  def wire(value) when is_list(value), do: Enum.map(value, &wire/1)

  def wire(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  def wire(value), do: value
end
