defmodule ReqManagedAgents.Evidence.Content do
  @moduledoc false
  alias ReqManagedAgents.Evidence.{Adapter, Record}

  def apply(record, policy, selector \\ :standalone)
  def apply(%Record{kind: :local} = record, _, _), do: record
  def apply(%Record{content_state: :retained} = record, :retain, _), do: record

  def apply(%Record{} = record, _, selector) do
    state = if record.content_state == :redacted, do: :redacted, else: :dropped

    %{
      record
      | payload: Adapter.interpret(record.payload, selector).safe_payload,
        content_state: state
    }
  end
end
