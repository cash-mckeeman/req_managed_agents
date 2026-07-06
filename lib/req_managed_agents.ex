defmodule ReqManagedAgents do
  @moduledoc """
  Provider-agnostic Elixir client for agent runtimes — one Session loop, any loop host.

  The loop host runs the agent loop — a managed provider server-side, or
  `ReqManagedAgents.Providers.Local` in-process. Your custom tools execute
  locally regardless of which host runs the loop, so your data and code never
  leave your node. The loop host only ever sees each tool's name, description,
  input schema, and the text result you return.

  Three backends ship behind the same `ReqManagedAgents.Provider` behaviour:

    * `ReqManagedAgents.Providers.ClaudeManagedAgents` — Anthropic Claude
      Managed Agents (public beta), `:streaming` over long-lived SSE
    * `ReqManagedAgents.Providers.BedrockAgentCore` — AWS Bedrock AgentCore
      Harness, `:request_response` over signed invokes (requires the optional
      `:ex_aws_auth` and `:aws_event_stream` deps)
    * `ReqManagedAgents.Providers.Local` — in-process loop over a pluggable
      `chat_fun` (default: ReqLLM via the optional `req_llm` dep)

  Whichever backend, `ReqManagedAgents.Session.run/2` returns the same
  `ReqManagedAgents.SessionResult` — terminal, text, tool uses, token usage.

  See `ReqManagedAgents.Client` for the Anthropic control plane,
  `ReqManagedAgents.Session` for the batteries-included loop, and the README
  and `examples/` for runnable, commented walkthroughs.
  """

  @doc "Build a control-plane client. See `ReqManagedAgents.Client.new/1`."
  defdelegate new(opts \\ []), to: ReqManagedAgents.Client

  @doc "Start a live managed-agent session (Claude Managed Agents). See `ReqManagedAgents.Session.start_link/2`."
  def start_session(opts),
    do: ReqManagedAgents.Session.start_link(ReqManagedAgents.Providers.ClaudeManagedAgents, opts)

  @doc """
  Run a managed-agent session synchronously to completion, returning
  `{:ok, %ReqManagedAgents.SessionResult{}}` (terminal, stop_reason, text,
  tool uses, usage, events) or `{:error, reason}` (incl. `{:error, :timeout}`).

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

  @doc """
  Build-if-absent for an environment image (Claude Managed Agents): content-addressed
  by spec digest, named `<base>_<digest8>`, reused on every identical spec. See
  `ReqManagedAgents.Provisioner.Environments`.
  """
  defdelegate ensure_environment(client, env_spec, opts \\ []),
    to: ReqManagedAgents.Provisioner.Environments

  defdelegate ensure_agent(client, agent_spec, opts \\ []), to: ReqManagedAgents.Provisioner
  defdelegate tag_agent(base, tag, digest_or_handle, opts \\ []), to: ReqManagedAgents.Provisioner
  defdelegate resolve_agent(ref, opts \\ []), to: ReqManagedAgents.Provisioner
  defdelegate prune_agents(client, base, opts \\ []), to: ReqManagedAgents.Provisioner

  @doc "Tear down a provisioned resource and evict it from the provision cache."
  @spec teardown(module(), ReqManagedAgents.Provider.handle(), keyword()) ::
          :ok | {:error, term()}
  def teardown(provider, handle, opts \\ []) do
    if function_exported?(provider, :teardown, 2) do
      case provider.teardown(handle, opts) do
        :ok ->
          ReqManagedAgents.Provisioner.evict(handle, opts)
          :ok

        error ->
          error
      end
    else
      {:error, :not_supported}
    end
  end
end
