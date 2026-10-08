defmodule ReqManagedAgents.Evidence.Record.Payload do
  @moduledoc "Validated local lifecycle metadata, without exception or request bodies."
  alias ReqManagedAgents.Evidence.{Error, Validation}
  @enforce_keys [:type, :invocation_id]
  defstruct [
    :type,
    :invocation_id,
    :attempt_id,
    :parent_attempt_id,
    :clock_id,
    :started_ticks,
    :ended_ticks,
    :result,
    :error_code,
    :tool_use_id
  ]

  @type kind ::
          :invocation_started
          | :invocation_finished
          | :attempt_started
          | :attempt_finished
          | :transport_failed
          | :retry_decided
          | :tool_started
          | :tool_finished
  @type t :: %__MODULE__{
          type: kind(),
          invocation_id: String.t(),
          attempt_id: String.t() | nil,
          parent_attempt_id: String.t() | nil,
          clock_id: String.t() | nil,
          started_ticks: integer() | nil,
          ended_ticks: integer() | nil,
          result: :ok | :error | :cancelled | nil,
          error_code: String.t() | nil,
          tool_use_id: String.t() | nil
        }
  @types Map.new(
           ~w(invocation_started invocation_finished attempt_started attempt_finished transport_failed retry_decided tool_started tool_finished)a,
           &{Atom.to_string(&1), &1}
         )
  @results %{"ok" => :ok, "error" => :error, "cancelled" => :cancelled}
  @fields ~w(type invocation_id attempt_id parent_attempt_id clock_id started_ticks ended_ticks result error_code tool_use_id)a

  @doc "Rejects unknown lifecycle fields and unscoped or reversed monotonic intervals."
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    specs =
      [
        {:type, &Validation.enum(&1, @types), nil},
        {:invocation_id, &Validation.id/1, nil},
        {:result, &Validation.optional(&1, fn v -> Validation.enum(v, @results) end), nil}
      ] ++
        Enum.map(
          ~w(attempt_id parent_attempt_id clock_id error_code tool_use_id)a,
          &{&1, fn v -> Validation.optional(v, fn x -> Validation.safe_id(x) end) end, nil}
        ) ++
        Enum.map(
          [:started_ticks, :ended_ticks],
          &{&1, fn v -> Validation.optional(v, fn x -> Validation.integer(x) end) end, nil}
        )

    with true <- Validation.only_keys?(attrs, @fields),
         {:ok, fields} <- Validation.fields(attrs, specs),
         true <- valid_lifecycle?(fields),
         true <- valid_ticks?(fields) do
      {:ok, struct!(__MODULE__, fields)}
    else
      _ -> Error.error(:invalid_input)
    end
  end

  def new(_), do: Error.error(:invalid_input)

  defp valid_lifecycle?(%{type: type, attempt_id: attempt_id}) do
    type in [:invocation_started, :invocation_finished] or is_binary(attempt_id)
  end

  defp valid_ticks?(%{started_ticks: nil, ended_ticks: nil}), do: true
  defp valid_ticks?(%{clock_id: nil}), do: false

  defp valid_ticks?(%{started_ticks: from, ended_ticks: to})
       when is_integer(from) and is_integer(to), do: from <= to

  defp valid_ticks?(_), do: true
end

defmodule ReqManagedAgents.Evidence.Record do
  @moduledoc "Source-local observations; native payload maps are provider-verbatim JSON at the raw edge."
  alias ReqManagedAgents.Evidence.{Content, Error, Options, Validation}
  alias ReqManagedAgents.Evidence.Record.Payload
  @enforce_keys [:id, :source_id, :ordinal, :observed_at, :clock, :kind, :payload, :content_state]
  defstruct [
    :id,
    :source_id,
    :native_id,
    :ordinal,
    :invocation_id,
    :attempt_id,
    :observed_at,
    :occurred_at,
    :clock,
    :clock_id,
    :monotonic_ticks,
    :kind,
    :payload,
    :content_state
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          source_id: String.t(),
          native_id: String.t() | nil,
          ordinal: pos_integer(),
          invocation_id: String.t() | nil,
          attempt_id: String.t() | nil,
          observed_at: DateTime.t(),
          occurred_at: DateTime.t() | nil,
          clock: :wall | :monotonic | :none,
          clock_id: String.t() | nil,
          monotonic_ticks: integer() | nil,
          kind: :native | :local,
          payload: map() | Payload.t(),
          content_state: :retained | :dropped | :redacted
        }
  @clocks %{"wall" => :wall, "monotonic" => :monotonic, "none" => :none}
  @kinds %{"native" => :native, "local" => :local}
  @states %{"retained" => :retained, "dropped" => :dropped, "redacted" => :redacted}

  @doc "Validates record metadata and applies content policy; malformed native time becomes nil."
  @spec new(map(), keyword() | Options.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs, opts \\ []) do
    with {:ok, options} <- Options.new(opts), {:ok, record} <- parse(attrs) do
      {:ok, Content.apply(record, options.content)}
    end
  end

  @doc false
  @spec parse(map()) :: {:ok, t()} | {:error, Error.t()}
  def parse(attrs) when is_map(attrs) do
    specs =
      [
        {:id, &Validation.id/1, nil},
        {:source_id, &Validation.id/1, nil},
        {:ordinal, &Validation.positive/1, nil},
        {:observed_at, &Validation.utc/1, nil},
        {:clock, &Validation.enum(&1, @clocks), :none},
        {:kind, &Validation.enum(&1, @kinds), nil},
        {:content_state, &Validation.enum(&1, @states), :retained},
        {:monotonic_ticks, &Validation.optional(&1, fn v -> Validation.integer(v) end), nil}
      ] ++
        Enum.map(
          ~w(native_id invocation_id attempt_id clock_id)a,
          &{&1, fn v -> Validation.optional(v, fn x -> Validation.id(x) end) end, nil}
        )

    with {:ok, fields} <- Validation.fields(attrs, specs),
         true <- valid_clock?(fields),
         {:ok, payload} <- payload(fields.kind, Validation.get(attrs, :payload)),
         true <- consistent_local?(fields, payload) do
      occurred_at =
        case Validation.utc(Validation.get(attrs, :occurred_at)) do
          {:ok, time} -> time
          _ -> nil
        end

      {:ok, struct!(__MODULE__, Map.merge(fields, %{payload: payload, occurred_at: occurred_at}))}
    else
      _ -> Error.error(:invalid_input)
    end
  end

  def parse(_), do: Error.error(:invalid_input)

  defp payload(:local, value), do: Payload.new(value)

  defp payload(:native, value) when is_map(value) do
    if Validation.json?(value), do: {:ok, value}, else: Error.error(:invalid_input)
  end

  defp payload(_, _), do: Error.error(:invalid_input)

  defp valid_clock?(%{clock: :monotonic, clock_id: id, monotonic_ticks: ticks}),
    do: is_binary(id) and is_integer(ticks)

  defp valid_clock?(%{clock_id: nil, monotonic_ticks: nil}), do: true
  defp valid_clock?(_), do: false
  defp consistent_local?(%{kind: :native}, _), do: true

  defp consistent_local?(fields, %Payload{} = payload) do
    fields.native_id == nil and fields.invocation_id == payload.invocation_id and
      fields.attempt_id == payload.attempt_id and
      (payload.clock_id == nil or fields.clock_id == payload.clock_id)
  end
end
