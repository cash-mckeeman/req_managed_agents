defmodule ReqManagedAgents.Acceptance.Basic do
  @moduledoc false
  alias ReqManagedAgents.Acceptance.{Assertion, Context, Observation}
  alias ReqManagedAgents.Evidence.{Capture, Recorder}
  alias ReqManagedAgents.Session

  @doc false
  @typedoc "Raw native failure is returned only to the provider acceptance edge for interpretation; it is never rendered."
  @type native_failure :: {:execution_failed, term()}
  @spec session(Context.t(), module(), keyword()) ::
          {:ok, [Observation.t()]} | {:error, native_failure(), [Observation.t()]}
  def session(context, provider, native_options) do
    remaining = context.deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      policy = [
        handler: fn _, _, _ -> {:error, :tool_execution_not_permitted} end,
        turn_guard: fn _ -> {:halt, :acceptance_first_turn} end,
        max_turns: 1,
        timeout: remaining,
        deadline: context.deadline,
        evidence_recorder: context.recorder
      ]

      provider |> Session.run(Keyword.merge(native_options, policy)) |> observed(context)
    else
      evidence = Recorder.begin(context.recorder, provider)
      Recorder.observe(evidence, :invocation_end, result: :error, error_code: "deadline_exceeded")
      observed({:error, :deadline_exceeded}, context)
    end
  end

  defp observed({:ok, _}, context), do: stopped("execution_finished", context)

  defp observed({:error, {:halted, :acceptance_first_turn}}, context),
    do: stopped("local_first_turn_halt", context)

  defp observed({:error, reason}, _context) do
    {:ok, observation} = Observation.new("execution_failed", :failed, [])
    {:error, {:execution_failed, reason}, [observation]}
  end

  defp stopped(name, context) do
    refs =
      case Recorder.snapshot(context.recorder) do
        {:ok, evidence} -> references(evidence.records)
        _ -> []
      end

    {:ok, observation} = Observation.new(name, :passed, refs)
    {:ok, [observation]}
  end

  @doc false
  @spec capture(Context.t(), [Observation.t()]) :: {:ok, Capture.t()} | {:error, term()}
  def capture(context, observations) do
    observations
    |> Enum.map(& &1.capture)
    |> Enum.reject(&is_nil/1)
    |> List.last()
    |> case do
      %Capture{} = evidence -> {:ok, evidence}
      nil -> Recorder.snapshot(context.recorder)
    end
  end

  @doc false
  @spec assess(Context.t(), [Observation.t()], :agentcore | :claude_managed_agents) :: [
          Assertion.t()
        ]
  def assess(context, observations, provider) do
    case capture(context, observations) do
      {:ok, evidence} ->
        assess_capture(evidence, observations, provider)

      _ ->
        [
          predicate("native_activity", :inconclusive, []),
          predicate("native_completion", :inconclusive, []),
          predicate("bounded_capture", :failed, [])
        ]
    end
  end

  defp assess_capture(evidence, observations, provider) do
    kinds = Map.new(evidence.sources, &{&1.id, &1.kind})

    native =
      Enum.filter(evidence.records, fn record ->
        record.kind == :native and
          Map.get(kinds, record.source_id) in [:agentcore_stream, :claude_session]
      end)

    complete = Enum.filter(native, &terminal?(&1.payload, provider))

    [
      predicate("native_activity", presence(native), native),
      predicate("native_completion", presence(complete), complete),
      predicate("bounded_capture", capture_status(evidence, observations), evidence.records)
    ]
  end

  defp capture_status(evidence, observations) do
    cond do
      Enum.any?(observations, &(&1.outcome == :failed)) -> :failed
      evidence.diagnostics != [] -> :inconclusive
      Enum.any?(evidence.sources, &(&1.status != :complete)) -> :inconclusive
      evidence.records == [] -> :inconclusive
      true -> :passed
    end
  end

  defp predicate(name, outcome, records) do
    {:ok, assertion} = Assertion.new(name, outcome, references(records))
    assertion
  end

  defp references(records), do: Enum.map(records, &(&1.source_id <> ":" <> &1.id))
  defp presence([]), do: :inconclusive
  defp presence(_), do: :passed

  defp terminal?(%{"messageStop" => %{"stopReason" => reason}}, :agentcore),
    do: reason in ["end_turn", "stop_sequence"]

  defp terminal?(
         %{"type" => "session.status_idle", "stop_reason" => %{"type" => reason}},
         :claude_managed_agents
       ),
       do: reason in ["end_turn", "satisfied"]

  defp terminal?(_, _), do: false
end
