defmodule ReqManagedAgents.Handler do
  @moduledoc """
  Behaviour a consumer implements to plug local tool execution and event handling
  into `ReqManagedAgents.Session`. This is the "tools stay local" seam: the
  managed loop runs on Anthropic's side and calls back into `handle_tool_call/3`
  on your node.
  """

  @doc """
  Run a custom tool locally. `name` and `input` come from the
  `agent.custom_tool_use` event; `ctx` is the `:context` passed at session start.
  Return `{:ok, text}` (sent as the tool result) or `{:error, text}` (sent with
  `is_error: true`).
  """
  @callback handle_tool_call(name :: String.t(), input :: map(), ctx :: term()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc "Optional: react to non-tool events (assistant messages, status, errors)."
  @callback handle_event(event :: map(), ctx :: term()) :: :ok

  @optional_callbacks handle_event: 2
end
