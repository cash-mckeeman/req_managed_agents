defmodule ReqManagedAgents.Profile do
  @moduledoc """
  Server wire-compat profile. `:anthropic` is identity (Anthropic cloud shape).
  `:jido` encodes the 4 remaps proven by the jido_managed_agents handshake spike:
  (1) tool-use name/input nested under content[0]/payload; (2) end_turn signalled
  as status_idle + null stop_reason (gate on "agent seen"); (3) /events/stream path;
  (4) pagination cursor (after vs next_page — handled in the paging layer).
  """
  @type t :: :anthropic | :jido

  @typedoc "A terminal verdict for a Managed Agents idle/terminal event."
  @type terminal :: :end_turn | :terminated | :error | :retries_exhausted

  @spec tool_use(t(), map()) :: {String.t(), map()}
  def tool_use(:anthropic, %{"name" => name, "input" => input}), do: {name, input}

  def tool_use(:jido, %{"content" => [%{"name" => name, "payload" => input} | _]}),
    do: {name, input}

  @spec events_stream_path(t(), String.t()) :: String.t()
  def events_stream_path(:anthropic, sid), do: "/v1/sessions/#{sid}/stream"
  def events_stream_path(:jido, sid), do: "/v1/sessions/#{sid}/events/stream"

  @doc """
  Terminal verdict for an idle/terminal event. Returns a terminal atom or `false`.
  For :jido, a creation-time status_idle (before any agent event) is NOT terminal.
  """
  @spec terminal?(t(), map(), boolean()) :: terminal() | false
  def terminal?(:anthropic, event, _seen?), do: anthropic_terminal(event)

  def terminal?(:jido, %{"type" => "session.status_idle", "stop_reason" => nil}, true),
    do: :end_turn

  def terminal?(:jido, %{"type" => "session.status_idle", "stop_reason" => nil}, false), do: false
  def terminal?(:jido, event, _seen?), do: anthropic_terminal(event)

  # Terminal verdict for an idle/terminal event, or false when it is not terminal (a
  # `requires_action` or unknown idle, or any non-status event). The wire-compat
  # counterpart to `Provider.terminal/1`, but it keeps the richer atoms the Managed
  # Agents wire distinguishes (`:error`, `:retries_exhausted`) rather than collapsing.
  defp anthropic_terminal(%{"type" => "session.status_idle", "stop_reason" => %{"type" => reason}}) do
    case reason do
      "end_turn" -> :end_turn
      "retries_exhausted" -> :retries_exhausted
      _ -> false
    end
  end

  defp anthropic_terminal(%{"type" => "session.status_terminated"}), do: :terminated
  defp anthropic_terminal(%{"type" => "session.error"}), do: :error
  defp anthropic_terminal(_), do: false
end
