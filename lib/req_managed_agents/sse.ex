defmodule ReqManagedAgents.SSE do
  @moduledoc """
  Pure Server-Sent-Events frame decoder for the Managed Agents event stream.

  `decode/1` takes an accumulated buffer and returns `{events, remainder}` where
  `events` are the decoded JSON maps for every *complete* frame in the buffer and
  `remainder` is the trailing partial frame to prepend to the next chunk. No
  network, no state — call it repeatedly as bytes arrive.
  """

  @doc """
  Decode complete SSE frames from `buffer`.

  Frames are separated by a blank line (`\\n\\n` or `\\r\\n\\r\\n`). Within a
  frame, `data:` lines are concatenated with newlines and JSON-decoded. Comment
  lines (starting `:`) and non-`data:` lines are ignored. Undecodable JSON is
  dropped.
  """
  @spec decode(binary()) :: {[map()], binary()}
  def decode(buffer) when is_binary(buffer) do
    normalized = String.replace(buffer, "\r\n", "\n")
    parts = String.split(normalized, "\n\n")
    {complete, [remainder]} = Enum.split(parts, -1)

    events = Enum.flat_map(complete, &decode_frame/1)
    {events, remainder}
  end

  defp decode_frame(frame) do
    data =
      frame
      |> String.split("\n")
      |> Enum.flat_map(fn
        ":" <> _comment -> []
        "data:" <> rest -> [String.trim_leading(rest)]
        _ -> []
      end)

    case data do
      [] ->
        []

      lines ->
        json = Enum.join(lines, "\n")

        case Jason.decode(json) do
          {:ok, decoded} -> [decoded]
          {:error, _} -> []
        end
    end
  end
end
