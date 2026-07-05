defmodule ReqManagedAgents.Local.Retry do
  @moduledoc false
  # Transient-error retry for the chat_fun (HTTP 408/≥500 + transport; exponential
  # backoff). Relocated from biai-managed-agents Core.Runner.Retry.
  require Logger
  defstruct max_retries: 3, backoff_ms: 1000, sleep_fun: &Process.sleep/1

  @type t :: %__MODULE__{
          max_retries: non_neg_integer(),
          backoff_ms: pos_integer(),
          sleep_fun: (non_neg_integer() -> any())
        }

  @transient_transport [:timeout, :closed, :econnrefused, :econnreset, :connect_timeout]

  @doc "Wrap a chat_fun so transient failures retry; returns a fn with the same (request) shape."
  @spec wrap((map() -> {:ok, map()} | {:error, term()}), t()) ::
          (map() -> {:ok, map()} | {:error, term()})
  def wrap(chat_fun, %__MODULE__{} = cfg) do
    fn request -> attempt(chat_fun, request, cfg, 0) end
  end

  defp attempt(chat_fun, request, cfg, n) do
    case chat_fun.(request) do
      {:error, reason} = err ->
        if n < cfg.max_retries and transient?(reason) do
          delay = cfg.backoff_ms * Integer.pow(2, n)

          Logger.warning(
            "[ReqManagedAgents.Providers.Local] transient chat error (#{describe(reason)}); " <>
              "retry #{n + 1}/#{cfg.max_retries} after #{delay}ms"
          )

          cfg.sleep_fun.(delay)
          attempt(chat_fun, request, cfg, n + 1)
        else
          err
        end

      other ->
        other
    end
  end

  @doc false
  def transient?(%{status: s}) when is_integer(s), do: s == 408 or s >= 500
  def transient?(%{reason: r}) when r in @transient_transport, do: true
  def transient?(%{cause: c}) when is_atom(c) and c in @transient_transport, do: true
  def transient?(_), do: false

  defp describe(%{status: s}) when is_integer(s), do: "status=#{s}"
  defp describe(r), do: inspect(r) |> String.slice(0, 80)
end
