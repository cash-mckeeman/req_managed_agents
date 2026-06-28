defmodule ReqManagedAgents.AgentCore.EventStream do
  @moduledoc """
  Ported from `ReqLLM.Providers.AmazonBedrock.AWSEventStream` (req_llm). `req_llm` is
  intentionally NOT a dependency of this multi-provider managed-agents client — see MIM-43.
  Adapted to a `{messages, remainder}` chunked shape for incremental stream decoding.

  # TODO(extract): candidate for a shared `aws_event_stream` lib (both req_llm and
  # req_managed_agents) — see MIM-43.

  ## Frame layout

  Each vnd.amazon.eventstream frame:
  - 4 bytes: total message length (big-endian)
  - 4 bytes: headers length (big-endian)
  - 4 bytes: prelude CRC32
  - N bytes: headers (type-7 string key-value pairs; ported faithfully from req_llm)
  - M bytes: payload (direct JSON for AgentCore ConverseStream)
  - 4 bytes: message CRC32

  Truncated frames (total > available bytes, or < 12 B prelude) are returned intact as the
  remainder for the next chunk. Prelude or message CRC mismatch causes the frame to be dropped
  (same recovery posture as req_llm). Payloads that fail `Jason.decode` are silently dropped.
  """

  # Prelude = total_len(4) + headers_len(4) + prelude_crc(4)
  @prelude_size 12
  @crc_size 4
  @min_message_size @prelude_size + @crc_size

  @spec decode(binary()) :: {[map()], binary()}
  def decode(buffer) when is_binary(buffer), do: decode_loop(buffer, [])

  defp decode_loop(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  defp decode_loop(buffer, acc) when byte_size(buffer) < @prelude_size do
    {Enum.reverse(acc), buffer}
  end

  defp decode_loop(buffer, acc) do
    <<total_len::big-32, headers_len::big-32, prelude_crc::32, rest::binary>> = buffer

    if total_len >= @min_message_size do
      body_len = total_len - @prelude_size - headers_len - @crc_size
      needed = headers_len + body_len + @crc_size

      if body_len >= 0 and byte_size(rest) >= needed do
        <<headers_bin::binary-size(^headers_len), body::binary-size(^body_len), msg_crc::32,
          tail::binary>> = rest

        # Verify prelude CRC. Mirror req_llm: drop frame on mismatch rather than halting.
        prelude = <<total_len::big-32, headers_len::big-32>>

        acc =
          if :erlang.crc32(prelude) == prelude_crc do
            # Verify message CRC over prelude(8) + prelude_crc(4) + headers + payload —
            # i.e. every byte of the frame except the trailing 4-byte message CRC itself.
            message_without_crc = prelude <> <<prelude_crc::32>> <> headers_bin <> body

            if :erlang.crc32(message_without_crc) == msg_crc do
              # parse_headers is a faithful port of req_llm's header walker (type-7 strings only).
              # Called here so headers_bin is consumed and the port is reachable.
              # Result is available for event-type routing in future — AgentCore JSON is
              # self-describing so we do not need it to demux today.
              _headers = parse_headers(headers_bin)

              case Jason.decode(body) do
                {:ok, map} -> [map | acc]
                {:error, _} -> acc
              end
            else
              acc
            end
          else
            acc
          end

        decode_loop(tail, acc)
      else
        # Frame is incomplete — buffer the whole thing for the next chunk.
        {Enum.reverse(acc), buffer}
      end
    else
      # Declared total_len is below the minimum valid frame size — treat as incomplete.
      {Enum.reverse(acc), buffer}
    end
  end

  # Ported faithfully from req_llm `parse_headers/1` + `parse_header_pairs/2`.
  # Walks AWS Event Stream header triples: name-len(1B) + name + value-type(1B) + value.
  # Only type 7 (string) is parsed; all other value types stop traversal (mirrors req_llm).
  defp parse_headers(<<>>), do: %{}
  defp parse_headers(data), do: parse_header_pairs(data, %{})

  defp parse_header_pairs(<<>>, acc), do: acc

  defp parse_header_pairs(data, acc) do
    case data do
      <<name_len::8, rest::binary>> when byte_size(rest) >= name_len ->
        <<name::binary-size(^name_len), value_type::8, rest2::binary>> = rest

        case value_type do
          # String type (7) — the only type Bedrock / AgentCore emits
          7 when byte_size(rest2) >= 2 ->
            <<value_len::big-16, rest3::binary>> = rest2

            if byte_size(rest3) >= value_len do
              <<value::binary-size(^value_len), remaining::binary>> = rest3
              parse_header_pairs(remaining, Map.put(acc, name, value))
            else
              acc
            end

          # All other value types: stop (mirrors req_llm behaviour)
          _ ->
            acc
        end

      _ ->
        acc
    end
  end
end
