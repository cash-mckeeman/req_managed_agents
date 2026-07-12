defmodule ReqManagedAgents.Handler do
  @moduledoc """
  Behaviour a consumer implements to plug local tool execution and event handling
  into `ReqManagedAgents.Session`. This is the "tools stay local" seam: the
  managed loop runs on Anthropic's side and calls back into `handle_tool_call/3`
  on your node.

  Both callbacks have optional richer forms — `handle_tool_call/4` and
  `handle_event/3` — that additionally receive the `ReqManagedAgents.SessionInfo`
  (session id, provider module) for the running session. Export the higher arity
  and it is preferred; otherwise the classic form is called.

  `handle_event/2` is observational and **at-least-once**: on reconnect (Claude) or a
  retried turn (Bedrock AgentCore), events from an aborted attempt may be delivered
  before the successful attempt's. When no attempt succeeds (retries exhausted), events
  live-delivered here were still observed even though the run returns an error; error frames
  surfaced by the transport (e.g. a `"__stream_error__"` envelope on Bedrock AgentCore) may
  also appear on this observational surface. The canonical exactly-once record is
  `ReqManagedAgents.SessionResult.events`.

  `handle_tool_call/3` (and its `/4` form) is likewise **at-least-once**, not
  exactly-once: session recovery from a `requires_action` batch that resolves to
  zero tool uses (see `c:ReqManagedAgents.Provider.pending_tool_uses/1`), and
  reconnect re-drive after a stream drop, both re-run a tool call for a
  `tool_use` id that may already have been dispatched. Side-effecting handlers
  should be idempotent, or dedupe on `tool_use` id themselves.
  """

  @doc """
  Run a custom tool locally. `name` and `input` come from the
  `agent.custom_tool_use` event; `ctx` is the `:context` passed at session start.
  Return `{:ok, text}` (sent as the tool result) or `{:error, text}` (sent with
  `is_error: true`). See the moduledoc — this callback is at-least-once, not
  exactly-once.
  """
  @callback handle_tool_call(name :: String.t(), input :: map(), ctx :: term()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc """
  Optional richer form of `c:handle_tool_call/3`: also receives the
  `ReqManagedAgents.SessionInfo` for the running session (its `session_id`,
  provider module). When a module exports the 4-arity form it is preferred;
  otherwise the 3-arity form is called. Fn handlers may likewise be 3- or
  4-arity.
  """
  @callback handle_tool_call(
              name :: String.t(),
              input :: map(),
              ctx :: term(),
              info :: ReqManagedAgents.SessionInfo.t()
            ) :: {:ok, String.t()} | {:error, String.t()}

  @doc "Optional: react to non-tool events (assistant messages, status, errors)."
  @callback handle_event(event :: map(), ctx :: term()) :: :ok

  @doc "Optional richer form of `c:handle_event/2` that also receives the `ReqManagedAgents.SessionInfo`."
  @callback handle_event(event :: map(), ctx :: term(), info :: ReqManagedAgents.SessionInfo.t()) ::
              :ok

  @optional_callbacks handle_event: 2, handle_event: 3, handle_tool_call: 3, handle_tool_call: 4
end
