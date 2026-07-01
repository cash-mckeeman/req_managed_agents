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

  Runs synchronously and **blocks** until a terminal event or the `:timeout`. The
  session is started unlinked and monitored, and it traps exits, so an open failure
  or an unexpected stream/consumer crash is surfaced to you as `{:error, reason}`
  rather than killing the caller; handled stream errors are likewise returned as
  `{:error, reason}`. For a supervised, reconnecting loop use
  `ReqManagedAgents.Session.start_link/2` instead.

  This is the Claude convenience form of `ReqManagedAgents.Session.run/2` — i.e.
  `Session.run(ReqManagedAgents.Providers.ClaudeManagedAgents, opts)`.
  """
  def run_to_completion(opts),
    do: ReqManagedAgents.Session.run(ReqManagedAgents.Providers.ClaudeManagedAgents, opts)

  @doc """
  Provision (create-or-reuse) a provider's agent resource for `spec`, returning a durable
  `handle` you splat into `ReqManagedAgents.Session.run/2` opts. Cached in-process by
  `{provider, spec}`.
  """
  @spec provision(module(), ReqManagedAgents.Provider.spec(), keyword()) ::
          {:ok, ReqManagedAgents.Provider.handle()} | {:error, term()}
  def provision(provider, spec, opts \\ []),
    do: ReqManagedAgents.Provisioner.ensure(provider, spec, opts)

  @doc "Tear down a provisioned resource and evict it from the provision cache."
  @spec teardown(module(), ReqManagedAgents.Provider.handle(), keyword()) :: :ok | {:error, term()}
  def teardown(provider, handle, opts \\ []) do
    if function_exported?(provider, :teardown, 2) do
      case provider.teardown(handle, opts) do
        :ok ->
          ReqManagedAgents.Provisioner.evict(handle)
          :ok

        error ->
          error
      end
    else
      {:error, :not_supported}
    end
  end
end
