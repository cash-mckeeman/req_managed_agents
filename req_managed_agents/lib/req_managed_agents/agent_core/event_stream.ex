defmodule ReqManagedAgents.AgentCore.EventStream do
  @moduledoc """
  Adapter from `aws_event_stream`'s classified frames to the Converse envelope
  `ReqManagedAgents.AgentCore.Converse.parse/1` consumes.

  Framing, CRC verification, header parsing, `:message-type` classification, and
  Bedrock payload unwrap all live in `AWSEventStream` (the published binary
  `vnd.amazon.eventstream` codec). This module owns only the AgentCore-specific
  shaping of the classified frames:

    * `{:event, type, payload}`        -> `%{type => payload}` (the Converse
      envelope), or `payload` as-is when the frame carries no `:event-type`.
    * `{:exception, type, payload}` /
      `{:error, code, message}`        -> `%{"__stream_error__" => %{"type" => …,
      "message" => …}}`, so a server-side close (e.g. a ConverseStream
      ValidationException) surfaces as a distinct error rather than a silent
      terminal. `ReqManagedAgents.AgentCore`'s `stream_error/1`
      reads this shape.
    * malformed frames / payloads      -> dropped (the prior recovery posture).

  `decode/1`'s `{[map()], binary()}` contract and incremental (chunked-buffer)
  semantics are preserved exactly — `AWSEventStream.JSON.decode/1` is itself
  incremental, buffering an incomplete trailing frame as `remainder`.
  """

  alias ReqManagedAgents.AgentCore.Deps

  @spec decode(binary()) :: {[map()], binary()}
  def decode(buffer) when is_binary(buffer) do
    Deps.ensure!()
    {classified, remainder} = AWSEventStream.JSON.decode(buffer)
    {Enum.flat_map(classified, &to_envelope/1), remainder}
  end

  defp to_envelope({:event, nil, payload}), do: [payload]
  defp to_envelope({:event, type, payload}), do: [%{type => payload}]

  defp to_envelope({:exception, type, payload}),
    do: [%{"__stream_error__" => %{"type" => type, "message" => payload}}]

  defp to_envelope({:error, code, message}),
    do: [%{"__stream_error__" => %{"type" => code, "message" => message}}]

  defp to_envelope({:malformed_payload, _msg, _reason}), do: []
  defp to_envelope({:malformed_frame, _reason, _raw}), do: []
end
