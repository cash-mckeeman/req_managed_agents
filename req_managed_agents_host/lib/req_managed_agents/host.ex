defmodule ReqManagedAgents.Host do
  @moduledoc """
  Durable single-node session host over `req_managed_agents`.

  `send_message/3` finds, starts, or reattaches the live session for a caller-supplied
  external id, runs one turn to a terminal via `ReqManagedAgents.Session.run/2`, and returns
  the RMA `ReqManagedAgents.SessionResult`. This is the whole public surface; it sits upstream
  of any cross-node durable tier.

  ## Quickstart

      # store: an ETS-backed locator, process-local
      {:ok, _pid} = ReqManagedAgents.Host.Store.ETS.start_link(name: :sessions)
      store = {ReqManagedAgents.Host.Store.ETS, name: :sessions}

      opts = [provider: MyProvider, handler: MyHandler, store: store]

      {:ok, %ReqManagedAgents.SessionResult{text: text}} =
        ReqManagedAgents.Host.send_message("customer-42", "hello", opts)

      # same external id later (even after a crash or idle-detach) reattaches the
      # same upstream session instead of minting a new one
      {:ok, _result} = ReqManagedAgents.Host.send_message("customer-42", "follow-up", opts)

  Swap `Store.ETS` for `Store.DETS` (`file:` opt) when the locator itself must survive a
  BEAM restart, not just a process crash.
  """

  alias ReqManagedAgents.Host.{Config, SessionServer, SessionSupervisor}

  @doc """
  Deliver `message` to the live session for `external_id`, starting or reattaching it as
  needed, and block for the resulting `ReqManagedAgents.SessionResult`.

  `opts` is validated into a `ReqManagedAgents.Host.Config` (`:provider`, `:handler`, and
  `:store` are required); an invalid config short-circuits with `{:error, {:invalid_config,
  key}}` before any session work happens.
  """
  @spec send_message(String.t(), String.t(), keyword()) ::
          {:ok, ReqManagedAgents.SessionResult.t()} | {:error, term()}
  def send_message(external_id, message, opts)
      when is_binary(external_id) and is_binary(message) do
    with {:ok, %Config{} = config} <- Config.new(opts),
         {:ok, pid} <- SessionSupervisor.start_or_get(external_id, config) do
      SessionServer.deliver(pid, message)
    end
  end
end
