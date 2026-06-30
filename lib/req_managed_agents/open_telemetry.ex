defmodule ReqManagedAgents.OpenTelemetry do
  @moduledoc """
  OTel GenAI bridge for req_managed_agents (mirrors `ReqLLM.OpenTelemetry`).

  Two surfaces:
  - **Pure mappers** (`attributes_for/2`, delegating to `Attributes`) — the load-bearing
    capture surface a host (mimir-gateway) calls to normalize RMA events to `gen_ai.*`.
  - **Optional OTLP export** (`attach/1`) — emits spans only when the OTel SDK is loaded;
    no-ops otherwise. No `opentelemetry` dependency is taken.

  ## Scope

  Both backends now run through the unified `ReqManagedAgents.Session`, which emits
  `[:req_managed_agents, :session, :terminal | :tool_uses]` (plus the streaming
  `[:req_managed_agents, :stream | :tool, …]` events) regardless of provider — so this bridge
  covers AgentCore and Claude Managed Agents alike. (The old per-driver
  `[:req_managed_agents, :agent_core, …]` events were retired with the driver collapse.)
  """
  require Logger
  @compile {:no_warn_undefined, [:otel_tracer, :opentelemetry]}
  alias ReqManagedAgents.OpenTelemetry.Attributes

  @handler_id "req-managed-agents-otel"

  @events [
    [:req_managed_agents, :stream, :event],
    [:req_managed_agents, :tool, :stop],
    [:req_managed_agents, :tool, :exception],
    [:req_managed_agents, :session, :terminal]
  ]

  @spec events() :: [[atom()]]
  def events, do: @events

  @doc "Map a telemetry event name + metadata to `{gen_ai_event_type, gen_ai_attrs}`."
  @spec attributes_for([atom()], map()) :: {String.t(), map()}
  def attributes_for([:req_managed_agents, :stream, :event], meta),
    do: {stream_type(meta), Attributes.chat(meta)}

  def attributes_for([:req_managed_agents, :tool, _], meta),
    do: {"tool_result", Attributes.tool(meta)}

  def attributes_for([:req_managed_agents, :session, :terminal], meta),
    do: {"turn_complete", Attributes.terminal(meta)}

  # A tool_use event arrives as a stream event of type "agent.custom_tool_use";
  # other stream events are model output ("chat").
  defp stream_type(%{type: "agent.custom_tool_use"}), do: "tool_use"
  defp stream_type(%{"type" => "agent.custom_tool_use"}), do: "tool_use"
  defp stream_type(_), do: "chat"

  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(:otel_tracer)

  @spec attach(term()) :: :ok | {:error, term()}
  def attach(handler_id \\ @handler_id) do
    if available?() do
      :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, nil)
    else
      {:error, :opentelemetry_unavailable}
    end
  rescue
    _ -> {:error, :opentelemetry_unavailable}
  end

  @spec detach(term()) :: :ok | {:error, :not_found}
  def detach(handler_id \\ @handler_id), do: :telemetry.detach(handler_id)

  @doc false
  def handle_event(event, _measurements, metadata, _config) do
    {type, attrs} = attributes_for(event, metadata)
    emit_span(type, attrs)
    :ok
  rescue
    e ->
      Logger.warning("req_managed_agents OTel handler error: #{inspect(e)}")
      :ok
  end

  # Minimal span emission via the OTel Erlang API, guarded. The full ReqLLM-style
  # Adapter/Translator/Metrics machinery is intentionally not mirrored here.
  defp emit_span(type, attrs) do
    if available?() do
      :otel_tracer.with_span(
        :opentelemetry.get_tracer(:req_managed_agents),
        type,
        %{attributes: attrs},
        fn _ -> :ok end
      )
    end

    :ok
  rescue
    _ -> :ok
  end
end
