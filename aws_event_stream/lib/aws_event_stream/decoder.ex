defmodule AWSEventStream.Decoder do
  @moduledoc """
  Incremental decoder for `vnd.amazon.eventstream` frames.

  `decode/2` consumes as many whole frames as the buffer holds and returns
  `{results, rest}`, where `rest` is leftover bytes to prepend to the next
  chunk. Frame-decode errors are surfaced as `{:error, {reason, raw_frame}}`
  results (never silently dropped); pass `on_error: :skip` to drop them. Note
  that with `:skip`, a corrupt prelude silently discards the whole remaining
  buffer, since the frame bounds are then unknowable.

  Possible error reasons: `:invalid_prelude_crc`, `:invalid_message_crc`,
  `:invalid_message_length`, and `:invalid_headers` (the header block could not
  be parsed, e.g. an unknown header type or a value whose declared length runs
  past the frame). The prelude CRC is validated as soon as the 12-byte prelude
  is available — a corrupt prelude is reported immediately rather than waiting
  for an (untrustworthy) declared frame length to arrive; since the frame bounds
  are then unknowable, the error carries the whole remaining buffer and decoding
  stops. Malformed input is always surfaced as an error, never raised.
  """
  alias AWSEventStream.{Header, Message}

  @prelude_size 12
  @crc_size 4
  @min_size @prelude_size + @crc_size

  @type result :: {:ok, Message.t()} | {:error, {atom(), binary()}}

  @spec decode(binary(), keyword()) :: {[result()], binary()}
  def decode(buffer, opts \\ []) when is_binary(buffer) do
    on_error = Keyword.get(opts, :on_error, :keep)
    {results, rest} = decode_loop(buffer, [])

    results =
      if on_error == :skip, do: Enum.reject(results, &match?({:error, _}, &1)), else: results

    {results, rest}
  end

  defp decode_loop(buffer, acc) when byte_size(buffer) < @prelude_size do
    {Enum.reverse(acc), buffer}
  end

  defp decode_loop(<<total::big-32, hlen::big-32, pcrc::big-32, rest::binary>> = buffer, acc) do
    cond do
      :erlang.crc32(<<total::big-32, hlen::big-32>>) != pcrc ->
        # The prelude fails its own checksum, so total_length cannot be trusted
        # to bound the frame — attach the whole remaining buffer and stop.
        {Enum.reverse([{:error, {:invalid_prelude_crc, buffer}} | acc]), <<>>}

      total < @min_size ->
        {Enum.reverse([{:error, {:invalid_message_length, buffer}} | acc]), <<>>}

      byte_size(buffer) < total ->
        # whole frame not yet available — hand the buffer back for the next chunk
        {Enum.reverse(acc), buffer}

      true ->
        body_len = total - @prelude_size - hlen - @crc_size
        frame = binary_part(buffer, 0, total)

        if body_len < 0 do
          tail = binary_part(buffer, total, byte_size(buffer) - total)
          decode_loop(tail, [{:error, {:invalid_message_length, frame}} | acc])
        else
          <<headers_bin::binary-size(^hlen), payload::binary-size(^body_len), mcrc::big-32,
            tail::binary>> = rest

          result = verify(total, headers_bin, payload, mcrc, frame)
          decode_loop(tail, [result | acc])
        end
    end
  end

  defp verify(total, headers_bin, payload, mcrc, frame) do
    if :erlang.crc32(binary_part(frame, 0, total - @crc_size)) != mcrc do
      {:error, {:invalid_message_crc, frame}}
    else
      case safe_decode_headers(headers_bin) do
        {:ok, headers} -> {:ok, %Message{headers: headers, payload: payload}}
        :error -> {:error, {:invalid_headers, frame}}
      end
    end
  end

  # Header.decode_all/1 only matches known type bytes (0-9) and assumes declared
  # lengths fit; an unknown type or a truncated value would raise. A CRC-valid
  # frame can still carry such headers (e.g. a future AWS header type), so parse
  # defensively and surface the failure as an error rather than crashing.
  defp safe_decode_headers(headers_bin) do
    {:ok, Header.decode_all(headers_bin)}
  rescue
    # The only ways a malformed header blob fails to parse: an unknown type byte
    # (no matching clause) or a value whose declared length runs past the bytes.
    # Rescue exactly those so a genuine code bug in Header.decode_all still crashes loudly.
    _ in [FunctionClauseError, MatchError] -> :error
  end
end
