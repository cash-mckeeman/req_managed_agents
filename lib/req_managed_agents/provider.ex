defmodule ReqManagedAgents.Provider do
  @moduledoc """
  Contract a streaming agent backend implements so one `ReqManagedAgents.Session` loop can
  drive ANY provider. A provider owns its transport **mode** and **invocation** end-to-end:

    * `:streaming` (push) — the server holds a connection open and pushes events; the client
      posts inputs out-of-band; a turn ends on a boundary event (`turn_boundary?/1`).
    * `:request_response` (pull) — the client calls (`poll_turn/2`) and the server answers the
      whole turn; resume re-sends the conversation delta.

  The canonical vocabulary uses Anthropic's `custom_tool_use` / `custom_tool_result` terms and
  names ONLY the client-side / return-of-control species; server-side tools are observe-only.

  **Raw preservation.** Normalization is additive, never lossy: `turn_outcome` carries the raw,
  JSON-decoded provider `events` it was derived from alongside the normalized fields, so a
  consumer can always cross-reference the provider's own wire documentation.
  """

  @typedoc "A raw, decoded provider event (string-keyed wire map)."
  @type event :: %{required(String.t()) => term()}

  @typedoc "A CUSTOM (client-side / return-of-control) tool call the client executes locally."
  @type custom_tool_use :: %{id: String.t(), name: String.t(), input: map()}

  @typedoc "A locally-produced result for a custom_tool_use — what the client submits to resume."
  @type custom_tool_result :: %{tool_use_id: String.t(), text: String.t(), is_error: boolean()}

  @typedoc "A SERVER-SIDE (provider-executed) tool call — observe-only, never actionable."
  @type server_tool_use :: %{id: String.t() | nil, name: String.t(), input: map()}

  @type terminal :: :end_turn | :requires_action | :terminated

  @type turn_outcome :: %{
          terminal: terminal(),
          stop_reason: String.t() | nil,
          custom_tool_uses: [custom_tool_use()],
          server_tool_uses: [server_tool_use()],
          text: String.t(),
          events: [event()]
        }

  @typedoc "Provider-private connection / session handle."
  @type conn :: term()
  @typedoc "Provider-private input that drives the next turn."
  @type input :: term()

  @callback mode() :: :streaming | :request_response

  @doc "Establish the connection/session; for :streaming, open the event stream to `subscriber`."
  @callback open(opts :: keyword(), subscriber :: pid()) :: {:ok, conn()} | {:error, term()}

  @doc "Input that kicks off the conversation (the initial user message)."
  @callback kickoff_input(opts :: keyword()) :: input()

  @doc "Input for a follow-up user message into a running session."
  @callback user_input(text :: String.t()) :: input()

  @doc "Input that resumes the loop after local tools ran (the mode's resume contract)."
  @callback resume_input(custom_tool_uses :: [custom_tool_use()], results :: [custom_tool_result()]) ::
              input()

  @doc "Fold a turn's accumulated events into the canonical turn outcome (carries raw `events`)."
  @callback normalize([event()]) :: turn_outcome()

  @doc ":request_response only — run one turn synchronously: send `input`, return the turn's events."
  @callback poll_turn(conn(), input()) :: {:ok, [event()], conn()} | {:error, term()}

  @doc ":streaming only — post `input`; events arrive asynchronously at the subscriber."
  @callback push_input(conn(), input()) :: :ok | {:error, term()}

  @doc ":streaming only — does this event close a turn (so accumulated events form one)?"
  @callback turn_boundary?(event()) :: boolean()

  @doc """
  :streaming only — after a stream drop, re-open the stream (delivering to `subscriber`) and
  return any unanswered tool calls to re-drive locally, plus the grown `seen` set.
  """
  @callback reconnect(conn(), subscriber :: pid(), seen :: MapSet.t()) ::
              {:ok, conn(), [custom_tool_use()], MapSet.t()} | {:error, term()}

  @optional_callbacks poll_turn: 2, push_input: 2, turn_boundary?: 1, reconnect: 3

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
