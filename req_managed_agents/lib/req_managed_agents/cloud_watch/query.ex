defmodule ReqManagedAgents.CloudWatch.Query do
  @moduledoc "An explicit CloudWatch log destination, UTC interval and native session/trace selection."
  alias ReqManagedAgents.CloudWatch.Client
  alias ReqManagedAgents.Evidence.{Error, Source, Validation}
  @enforce_keys [:region, :log_group, :from, :to, :session_id]
  defstruct [:region, :log_group, :from, :to, :session_id, trace_ids: []]

  @type t :: %__MODULE__{
          region: String.t(),
          log_group: String.t(),
          from: DateTime.t(),
          to: DateTime.t(),
          session_id: String.t(),
          trace_ids: [String.t()]
        }

  @doc "Rejects unknown fields, invalid destinations, non-UTC/reversed intervals and non-hex trace IDs."
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = attrs), do: attrs |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs) do
    with true <- Validation.only_keys?(attrs, ~w(region log_group from to session_id trace_ids)a),
         region = Validation.get(attrs, :region),
         true <- Client.valid_region?(region),
         group = Validation.get(attrs, :log_group),
         true <-
           is_binary(group) and byte_size(group) in 1..512 and
             Regex.match?(~r/\A[.\-_\/#A-Za-z0-9]+\z/, group),
         {:ok, interval} <- Source.Interval.new(attrs),
         true <- DateTime.to_unix(interval.from, :millisecond) >= 0,
         {:ok, session} <- Validation.safe_id(Validation.get(attrs, :session_id)),
         traces = Validation.get(attrs, :trace_ids, []),
         true <- is_list(traces) and Enum.all?(traces, &trace_id?/1) do
      {:ok,
       %__MODULE__{
         region: region,
         log_group: group,
         from: interval.from,
         to: interval.to,
         session_id: session,
         trace_ids: Enum.uniq(traces)
       }}
    else
      _ -> Error.error(:invalid_input)
    end
  end

  def new(_), do: Error.error(:invalid_input)

  @doc false
  @spec trace_id?(term()) :: boolean()
  def trace_id?(value),
    do:
      is_binary(value) and Regex.match?(~r/\A[0-9a-fA-F]{32}\z/, value) and
        value != String.duplicate("0", 32)
end
