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

  @doc "Start a supervised managed-agent session. See `ReqManagedAgents.Session.start_link/1`."
  defdelegate start_session(opts), to: ReqManagedAgents.Session, as: :start_link
end
