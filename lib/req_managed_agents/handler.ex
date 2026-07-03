defmodule ReqManagedAgents.Handler do
  @moduledoc """
  Behaviour a consumer implements to plug local tool execution and event handling
  into `ReqManagedAgents.Session`. This is the "tools stay local" seam: the
  managed loop runs on Anthropic's side and calls back into `handle_tool_call/3`
  on your node.

  Implement either arity of `handle_tool_call`; the 4-arity form wins when both exist.

  `handle_event/2` is observational and **at-least-once**: on reconnect (Claude) or a
  retried turn (Bedrock AgentCore), events from an aborted attempt may be delivered
  before the successful attempt's. When no attempt succeeds (retries exhausted), events
  live-delivered here were still observed even though the run returns an error; error frames
  surfaced by the transport (e.g. a `"__stream_error__"` envelope on Bedrock AgentCore) may
  also appear on this observational surface. The canonical exactly-once record is
  `ReqManagedAgents.SessionResult.events`.
  """

  @doc """
  Run a custom tool locally. `name` and `input` come from the
  `agent.custom_tool_use` event; `ctx` is the `:context` passed at session start.
  Return `{:ok, text}` (sent as the tool result) or `{:error, text}` (sent with
  `is_error: true`).
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
