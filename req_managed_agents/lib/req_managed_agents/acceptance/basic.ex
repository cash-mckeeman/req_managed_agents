defmodule ReqManagedAgents.Acceptance.Basic do
  @moduledoc false
  alias ReqManagedAgents.Acceptance.{Assertion, Context, Observation}
  alias ReqManagedAgents.Evidence.{Capture, Recorder}

  @doc false
  @spec session(Context.t(), module(), keyword()) ::
          {:ok, [Observation.t()]} | {:error, atom(), [Observation.t()]}
  def session(%Context{} = context, provider, opts) do
    common = [
      handler: fn _, _, _ -> {:error, :tool_execution_not_permitted} end,
      evidence_recorder: context.recorder,
      timeout: context.config.bounds.timeout_ms,
      max_turns: 1,
      turn_guard: fn _ -> {:halt, :acceptance_first_turn} end
    ]

    result = ReqManagedAgents.Session.run(provider, Keyword.merge(opts, common))

    case result do
      {:ok, _} ->
        observe(context, :passed, "execution_finished")

      {:error, {:halted, :acceptance_first_turn}} ->
        observe(context, :passed, "local_first_turn_halt")

      {:error, _} ->
        {:error, :execution_failed, observation(:failed, "execution_failed", [])}
    end
  end

  defp observe(context, outcome, name) do
    references =
      case Recorder.snapshot(context.recorder) do
        {:ok, capture} -> Enum.map(capture.records, &(&1.source_id <> ":" <> &1.id))
        _ -> []
      end

    {:ok, observation(outcome, name, references)}
  end

  defp observation(outcome, name, references) do
    {:ok, observation} = Observation.new(name, outcome, references)
    [observation]
  end

  @doc false
  @spec assess(Context.t(), [Observation.t()], atom()) :: [Assertion.t()]
  def assess(context, observations, provider) do
    case capture(context, observations) do
      {:ok, capture} -> predicates(capture, observations, provider)
      _ -> assertions([], [], [], :failed)
    end
  end

  @doc false
  @spec capture(Context.t(), [Observation.t()]) :: {:ok, Capture.t()} | {:error, term()}
  def capture(context, observations) do
    case Enum.find(Enum.reverse(observations), &match?(%Capture{}, &1.capture)) do
      nil -> Recorder.snapshot(context.recorder)
      observation -> {:ok, observation.capture}
    end
  end

  defp predicates(%Capture{} = capture, observations, provider) do
    kinds = Map.new(capture.sources, &{&1.id, &1.kind})

    native =
      Enum.filter(
        capture.records,
        &(&1.kind == :native and
            Map.get(kinds, &1.source_id) in [:agentcore_stream, :claude_session])
      )

    completed = Enum.filter(native, &complete?(&1.payload, provider))
    execution = if Enum.any?(observations, &(&1.outcome == :failed)), do: :failed, else: :passed

    coverage =
      if capture.diagnostics == [] and Enum.all?(capture.sources, &(&1.status == :complete)),
        do: :passed,
        else: :inconclusive

    assertions(
      native,
      completed,
      capture.records,
      if(execution == :failed, do: :failed, else: coverage)
    )
  end

  defp assertions(native, completed, records, coverage) do
    for {name, outcome, evidence} <- [
          {"native_activity", present(native), native},
          {"native_completion", present(completed), completed},
          {"bounded_capture", coverage, records}
        ] do
      refs = Enum.map(evidence, &(&1.source_id <> ":" <> &1.id))

      {:ok, assertion} =
        Assertion.new(
          name,
          if(outcome == :passed and refs == [], do: :inconclusive, else: outcome),
          refs
        )

      assertion
    end
  end

  defp present([]), do: :inconclusive
  defp present(_), do: :passed

  defp complete?(%{"messageStop" => %{"stopReason" => reason}}, :agentcore),
    do: reason in ["end_turn", "stop_sequence"]

  defp complete?(
         %{"type" => "session.status_idle", "stop_reason" => %{"type" => reason}},
         :claude_managed_agents
       ), do: reason in ["end_turn", "satisfied"]

  defp complete?(_, _), do: false
end
