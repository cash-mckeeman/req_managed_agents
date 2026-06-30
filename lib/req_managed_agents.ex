defmodule ReqManagedAgents do
  @moduledoc """
  Elixir client for Anthropic's Claude Managed Agents (public beta).

  Claude runs the agent loop server-side; your custom tools execute locally, so
  your data and code never leave your node. Anthropic only ever sees each tool's
  name, description, input schema, and the text result you return.

  See `ReqManagedAgents.Client` for the control plane, `ReqManagedAgents.Session`
  for the optional batteries-included loop, and the README for the headline
  example.
  """

  @doc "Build a control-plane client. See `ReqManagedAgents.Client.new/1`."
  defdelegate new(opts \\ []), to: ReqManagedAgents.Client

  @doc "Start a live managed-agent session (Claude Managed Agents). See `ReqManagedAgents.Session.start_link/2`."
  def start_session(opts),
    do: ReqManagedAgents.Session.start_link(ReqManagedAgents.Providers.ClaudeManagedAgents, opts)

  @doc """
  Run a managed-agent session synchronously to completion, returning
  `{:ok, %{terminal:, stop_reason:, events:}}` or `{:error, reason}` (incl.
  `{:error, :timeout}`).

  Runs in the calling process and **blocks** until a terminal event or the
  `:timeout`, selectively receiving its own stream messages (it leaves unrelated
  messages in the mailbox). The SSE consumer runs in a **linked** Task, so an
  unexpected consumer crash propagates to the caller; handled stream errors are
  returned as `{:error, reason}`. For a supervised, reconnecting loop use
  `ReqManagedAgents.Session` instead.
  """
  def run_to_completion(opts),
    do: ReqManagedAgents.Session.run(ReqManagedAgents.Providers.ClaudeManagedAgents, opts)
end
