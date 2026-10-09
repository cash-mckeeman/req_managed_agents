defmodule ReqManagedAgents.Evidence do
  @moduledoc """
  Version 1 private managed-agent evidence. The producer dialect is
  `managed_agent_evidence_v1`; retention does not authorize browser display.

  `Evidence.Recorder` observes live provider frames and local execution lifecycle events.
  `ReqManagedAgents.Providers.ClaudeManagedAgents.History` retrieves persisted Claude session and thread events without assigning
  local attempt identities. Native interpretation follows each declared source kind when
  restoring captures; content is dropped by default when constructing captures.
  """
  alias ReqManagedAgents.Evidence.{Capture, Error, Validation}

  @doc "Renders the public wire fields of a validated capture as a JSON-compatible map."
  @spec to_wire(Capture.t()) :: map()
  def to_wire(%Capture{} = capture) do
    %{
      "version" => capture.version,
      "capture_id" => capture.capture_id,
      "provider" => Atom.to_string(capture.provider),
      "session_id" => capture.session_id,
      "started_at" => Validation.wire(capture.started_at),
      "ended_at" => Validation.wire(capture.ended_at),
      "sources" =>
        Enum.map(
          capture.sources,
          &fields(&1, ~w(id kind scope interval status pages records_seen reason)a)
        ),
      "records" =>
        Enum.map(
          capture.records,
          &fields(
            &1,
            ~w(id source_id native_id ordinal invocation_id attempt_id observed_at occurred_at clock clock_id monotonic_ticks kind payload content_state)a
          )
        ),
      "correlations" =>
        Enum.map(
          capture.correlations,
          &fields(&1, ~w(from_record_id relation target evidence_record_ids)a)
        ),
      "diagnostics" =>
        Enum.map(capture.diagnostics, &fields(&1, ~w(code source_id record_id count message)a))
    }
  end

  @doc "Validates versioned decoded JSON, preserving explicitly retained content independently of UI policy."
  @spec from_wire(map()) :: {:ok, Capture.t()} | {:error, Error.t()}
  def from_wire(%{"version" => 1, "records" => records} = wire) when is_list(records) do
    if Enum.all?(
         records,
         &(is_map(&1) and Map.has_key?(&1, "content_state") and Map.has_key?(&1, "clock"))
       ) do
      Capture.restore(wire)
    else
      Error.error(:invalid_input)
    end
  end

  def from_wire(_), do: Error.error(:unsupported_version)

  defp fields(value, keys), do: value |> Map.take(keys) |> Validation.wire()
end
