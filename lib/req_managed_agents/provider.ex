defmodule ReqManagedAgents.Provider do
  @moduledoc """
  Contract a streaming agent backend implements so RMA's drivers can speak one
  canonical turn vocabulary regardless of wire protocol (binary EventStream vs SSE)
  or invocation model (per-turn request/response vs long-lived push stream). Both
  backends are stateful, session-scoped.

  The canonical vocabulary uses Anthropic's `custom_tool_use` / `custom_tool_result`
  terms and names ONLY the client-side / return-of-control species. Server-side /
  built-in tool activity stays in the raw `events` and is never represented here —
  the repository thesis is a provider-managed loop with locally executed tools.
  """

  @typedoc "A raw, decoded provider event (string-keyed wire map)."
  @type event :: %{required(String.t()) => term()}

  @typedoc "A client-side (return-of-control) tool call the client executes locally."
  @type custom_tool_use :: %{id: String.t(), name: String.t(), input: map()}

  @typedoc "A locally-produced result for a custom_tool_use — what the client submits to resume."
  @type custom_tool_result :: %{tool_use_id: String.t(), text: String.t(), is_error: boolean()}

  @type terminal :: :end_turn | :requires_action | :terminated

  @type turn_outcome :: %{
          terminal: terminal(),
          stop_reason: String.t() | nil,
          custom_tool_uses: [custom_tool_use()],
          text: String.t()
        }

  @doc "Reduce a streaming byte buffer to decoded events + leftover. (Transport seam.)"
  @callback decode(binary()) :: {[event()], binary()}

  @doc """
  Fold one turn's accumulated events into the canonical turn outcome. MUST surface
  only custom (client-side) tool calls in `custom_tool_uses`; server-side tool
  activity stays in the raw events and out of the actionable path.
  """
  @callback normalize([event()]) :: turn_outcome()

  @doc "Map a provider-raw stop reason to the canonical terminal atom."
  @callback terminal(stop_reason :: String.t() | nil) :: terminal()

  @doc """
  Build the provider-specific continuation that submits locally-executed tool results.
  Opaque to the driver.
  """
  @callback resume(custom_tool_uses :: [custom_tool_use()], results :: [custom_tool_result()]) ::
              term()

  @doc """
  Extract a canonical `custom_tool_result` from a `Tools.run/6` wire event
  (`user.custom_tool_result` shape), given the tool-use id it answers.
  """
  @spec result_of(String.t(), event()) :: custom_tool_result()
  def result_of(id, tool_event) when is_binary(id) and is_map(tool_event) do
    text = get_in(tool_event, ["content", Access.at(0), "text"]) || ""
    %{tool_use_id: id, text: text, is_error: tool_event["is_error"] == true}
  end
end
