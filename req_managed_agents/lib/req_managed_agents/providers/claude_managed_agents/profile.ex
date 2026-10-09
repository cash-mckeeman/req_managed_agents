defmodule ReqManagedAgents.Providers.ClaudeManagedAgents.Profile do
  @moduledoc """
  Claude Managed Agents wire profiles for tool calls, stream paths, and terminal events.

  `:anthropic` uses top-level tool inputs and explicit idle stop reasons. `:jido`
  uses nested tool inputs and treats a null idle stop reason as end-turn only
  after an agent event has been seen.
  """
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Event

  @type t :: :anthropic | :jido

  @doc "Extract the tool name and input for the selected wire profile."
  @spec tool_use(t(), map()) :: {String.t(), map()}
  def tool_use(:anthropic, %{"name" => name, "input" => input}), do: {name, input}

  def tool_use(:jido, %{"content" => [%{"name" => name, "payload" => input} | _]}),
    do: {name, input}

  @doc "Return the session stream path for the selected wire profile."
  @spec events_stream_path(t(), String.t()) :: String.t()
  def events_stream_path(:anthropic, sid), do: "/v1/sessions/#{sid}/stream"
  def events_stream_path(:jido, sid), do: "/v1/sessions/#{sid}/events/stream"

  @doc """
  Terminal verdict for an idle/terminal event. Returns a terminal atom or `false`.
  For :jido, a creation-time status_idle (before any agent event) is NOT terminal.
  """
  @spec terminal?(t(), map(), boolean()) ::
          Event.terminal() | false
  def terminal?(:anthropic, event, _seen?), do: anthropic_terminal(event)

  def terminal?(:jido, %{"type" => "session.status_idle", "stop_reason" => nil}, true),
    do: :end_turn

  def terminal?(:jido, %{"type" => "session.status_idle", "stop_reason" => nil}, false), do: false
  def terminal?(:jido, event, _seen?), do: anthropic_terminal(event)

  defp anthropic_terminal(event) do
    case Event.classify(event) do
      t when t in [:end_turn, :terminated, :error, :retries_exhausted] -> t
      _ -> false
    end
  end
end
