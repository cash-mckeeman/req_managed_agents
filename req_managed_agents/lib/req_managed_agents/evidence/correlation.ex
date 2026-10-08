defmodule ReqManagedAgents.Evidence.Correlation.Target do
  @moduledoc "An explicit namespaced link, with structured application and coding-session identities."
  alias ReqManagedAgents.Evidence.{Error, Validation}
  @enforce_keys [:namespace]
  defstruct [:namespace, :id, :request_id, :workflow_id, :step_id, :harness, :session_id]

  @type namespace ::
          :record | :session | :thread | :trace | :span | :tool_use | :application | :origin
  @type t :: %__MODULE__{
          namespace: namespace(),
          id: String.t() | nil,
          request_id: String.t() | nil,
          workflow_id: String.t() | nil,
          step_id: String.t() | nil,
          harness: :claude_code | :codex | nil,
          session_id: String.t() | nil
        }
  @namespaces Map.new(
                ~w(record session thread trace span tool_use application origin)a,
                &{Atom.to_string(&1), &1}
              )
  @harnesses %{"claude_code" => :claude_code, "codex" => :codex}
  @fields ~w(namespace id request_id workflow_id step_id harness session_id)a

  @doc "Rejects extra target fields and paths, URLs or whitespace in origin identities."
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    specs =
      [
        {:namespace, &Validation.enum(&1, @namespaces), nil},
        {:harness, &Validation.optional(&1, fn v -> Validation.enum(v, @harnesses) end), nil}
      ] ++
        Enum.map(
          ~w(id request_id workflow_id step_id session_id)a,
          &{&1, fn v -> Validation.optional(v, fn x -> Validation.safe_id(x) end) end, nil}
        )

    with true <- Validation.only_keys?(attrs, @fields),
         {:ok, fields} <- Validation.fields(attrs, specs),
         true <- valid?(fields) do
      {:ok, struct!(__MODULE__, fields)}
    else
      _ -> Error.error(:invalid_reference)
    end
  end

  def new(_), do: Error.error(:invalid_reference)

  defp valid?(%{namespace: :origin} = f),
    do:
      f.harness != nil and f.session_id != nil and
        empty?(f, ~w(id request_id workflow_id step_id)a)

  defp valid?(%{namespace: :application} = f),
    do:
      (f.request_id != nil or f.workflow_id != nil) and (f.step_id == nil or f.workflow_id != nil) and
        empty?(f, ~w(id harness session_id)a)

  defp valid?(f),
    do: f.id != nil and empty?(f, ~w(request_id workflow_id step_id harness session_id)a)

  defp empty?(f, fields), do: Enum.all?(fields, &(Map.fetch!(f, &1) == nil))
end

defmodule ReqManagedAgents.Evidence.Correlation do
  @moduledoc "An explicit relation supported by capture-local evidence record IDs."
  alias ReqManagedAgents.Evidence.Correlation.Target
  alias ReqManagedAgents.Evidence.{Error, Validation}
  @enforce_keys [:from_record_id, :relation, :target, :evidence_record_ids]
  defstruct [:from_record_id, :relation, :target, :evidence_record_ids]
  @type relation :: :same_session | :parent | :tool_result_for | :application | :origin
  @type t :: %__MODULE__{
          from_record_id: String.t(),
          relation: relation(),
          target: Target.t(),
          evidence_record_ids: [String.t()]
        }
  @relations Map.new(
               ~w(same_session parent tool_result_for application origin)a,
               &{Atom.to_string(&1), &1}
             )

  @doc "Validates relation/target shape; capture construction resolves record references."
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, fields} <-
           Validation.fields(attrs, [
             {:from_record_id, &Validation.id/1, nil},
             {:relation, &Validation.enum(&1, @relations), nil},
             {:target, &Target.new/1, nil},
             {:evidence_record_ids, &Validation.list(&1, fn v -> Validation.id(v) end), nil}
           ]),
         true <- fields.evidence_record_ids != [],
         true <- compatible?(fields.relation, fields.target.namespace) do
      {:ok, struct!(__MODULE__, fields)}
    else
      _ -> Error.error(:invalid_reference)
    end
  end

  defp compatible?(:origin, :origin), do: true
  defp compatible?(:application, :application), do: true

  defp compatible?(relation, namespace),
    do: relation not in [:origin, :application] and namespace not in [:origin, :application]
end
