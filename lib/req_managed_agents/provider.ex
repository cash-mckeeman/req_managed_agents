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

  @type terminal :: :end_turn | :requires_action | :terminated

  @typedoc "A provider-agnostic agent definition — the input to provisioning and the cache key."
  @type spec :: %{
          system_prompt: String.t(),
          tools: [map()],
          terminal_tool: String.t() | nil,
          model_config: term()
        }

  @typedoc "Provider-private handle to a provisioned, reusable server-side resource."
  @type handle :: term()

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
  @callback resume_input(tool_uses :: [ReqManagedAgents.ToolUse.t()], results :: [ReqManagedAgents.ToolResult.t()]) ::
              input()

  @doc "Fold a turn's accumulated events into the canonical turn outcome (carries raw `events`)."
  @callback normalize([event()]) :: ReqManagedAgents.TurnResult.t()

  @doc "Create (or look up) the provider-side agent resource for `spec`; return a durable handle."
  @callback provision(spec(), opts :: keyword()) :: {:ok, handle()} | {:error, term()}

  @doc "Delete the provider-side resource named by `handle`. `opts` carries the client / test seam."
  @callback teardown(handle(), opts :: keyword()) :: :ok | {:error, term()}

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
              {:ok, conn(), [ReqManagedAgents.ToolUse.t()], MapSet.t()} | {:error, term()}

  @optional_callbacks poll_turn: 2, push_input: 2, turn_boundary?: 1, reconnect: 3, teardown: 2

  @doc """
  Extract a canonical `%ToolResult{}` from a `Tools.run/6` wire event
  (`user.custom_tool_result` shape), given the tool-use id it answers.
  """
  @spec result_of(String.t(), event()) :: ReqManagedAgents.ToolResult.t()
  def result_of(id, tool_event) when is_binary(id) and is_map(tool_event) do
    text = get_in(tool_event, ["content", Access.at(0), "text"]) || ""
    %ReqManagedAgents.ToolResult{tool_use_id: id, text: text, is_error: tool_event["is_error"] == true}
  end
end
