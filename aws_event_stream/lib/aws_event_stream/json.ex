defmodule AWSEventStream.JSON do
  @moduledoc """
  Optional Bedrock/JSON convenience layer over the core codec.

  Classifies each frame by its `:message-type` header (`event` / `exception` /
  `error`) — **before** `:event-type` — into idiomatic tagged tuples, and
  unwraps Bedrock JSON payloads (`{"bytes": base64}` or direct JSON). Requires
  the optional `:jason` dependency.
  """
  alias AWSEventStream.{Decoder, Message}

  @type classified ::
          {:event, String.t() | nil, map()}
          | {:exception, String.t() | nil, map()}
          | {:error, String.t() | nil, String.t() | nil}
          | {:malformed_payload, Message.t(), term()}

  @spec decode(binary(), keyword()) ::
          {[classified() | {:malformed_frame, atom(), binary()}], binary()}
  def decode(buffer, opts \\ []) when is_binary(buffer) do
    {results, rest} = Decoder.decode(buffer, opts)

    classified =
      Enum.map(results, fn
        {:ok, msg} -> classify(msg)
        {:error, {reason, raw}} -> {:malformed_frame, reason, raw}
      end)

    {classified, rest}
  end

  @doc """
  Classify one decoded frame by its `:message-type` header.

  A frame's classification comes from its headers, so `:message-type` is checked
  **before** `:event-type`. Crucially, an `exception`/`error` frame is *always*
  surfaced as `{:exception, …}` / `{:error, …}` — a payload that fails to decode
  never downgrades a server-side close to `{:malformed_payload, …}`, since a
  close may legitimately carry a non-JSON or empty body. For an exception frame
  whose body is not a JSON object, the raw bytes are preserved under `"raw"`.
  Only `event` frames (the normal data path) surface `{:malformed_payload, …}`
  when their payload can't be decoded.
  """
  @spec classify(Message.t()) :: classified()
  def classify(%Message{} = msg) do
    case Message.header(msg, ":message-type") do
      "exception" ->
        {:exception, Message.header(msg, ":exception-type"), exception_payload(msg)}

      "error" ->
        {:error, Message.header(msg, ":error-code"), Message.header(msg, ":error-message")}

      _event_or_nil ->
        with {:ok, payload} <- decode_payload(msg) do
          {:event, Message.header(msg, ":event-type"), payload}
        end
    end
  end

  # The exception classification is fixed by the headers; the payload only enriches
  # it. Decode to a map when possible, otherwise keep the raw body under "raw" so a
  # server-side close (which may send a non-JSON/empty body) is never swallowed.
  defp exception_payload(%Message{payload: payload} = msg) do
    case decode_payload(msg) do
      {:ok, map} -> map
      {:malformed_payload, _msg, _reason} -> %{"raw" => payload}
    end
  end

  # Returns {:ok, map} or a {:malformed_payload, msg, reason} that propagates out of `with`.
  defp decode_payload(%Message{payload: payload} = msg) do
    case Jason.decode(payload) do
      {:ok, %{"bytes" => b64}} ->
        case Base.decode64(b64) do
          {:ok, raw} ->
            case Jason.decode(raw) do
              {:ok, map} when is_map(map) -> {:ok, map}
              {:ok, _non_object} -> {:malformed_payload, msg, :not_an_object}
              {:error, reason} -> {:malformed_payload, msg, reason}
            end

          :error ->
            {:malformed_payload, msg, :invalid_base64}
        end

      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _non_object} ->
        # Valid JSON but not an object (list/number/string) — payload must be a map.
        {:malformed_payload, msg, :not_an_object}

      {:error, reason} ->
        {:malformed_payload, msg, reason}
    end
  end
end
