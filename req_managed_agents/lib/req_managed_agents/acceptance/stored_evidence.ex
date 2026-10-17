defmodule ReqManagedAgents.Acceptance.StoredEvidence do
  @moduledoc false
  alias ReqManagedAgents.Acceptance.Assertion
  alias ReqManagedAgents.Evidence.{Record, Source}

  @doc false
  @spec assess([Source.t()], [Record.t()]) :: Assertion.t()
  def assess(sources, records) do
    ids = MapSet.new(sources, & &1.id)

    eligible =
      Enum.filter(
        records,
        &(&1.kind == :native and not &1.validation_issue? and MapSet.member?(ids, &1.source_id))
      )

    complete = sources != [] and Enum.all?(sources, &(&1.status == :complete))
    outcome = if complete and eligible != [], do: :passed, else: :inconclusive
    refs = Enum.map(eligible, &(&1.source_id <> ":" <> &1.id))
    {:ok, assertion} = Assertion.new("stored_evidence", outcome, refs)
    assertion
  end
end
