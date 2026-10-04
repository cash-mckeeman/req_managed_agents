defmodule ReqManagedAgents.Tools do
  @moduledoc false
  # Shared local-tool execution for Session and run_to_completion. Always returns
  # a `user.custom_tool_result` event; any failure becomes an `is_error` result so
  # the session never hangs.
  alias ReqManagedAgents.Event

  @type handler_fun ::
          (String.t(), map(), term() -> {:ok, String.t()} | {:error, String.t()})
          | (String.t(), map(), term(), ReqManagedAgents.SessionInfo.t() ->
               {:ok, String.t()} | {:error, String.t()})

  @spec run(
          module() | handler_fun(),
          String.t(),
          String.t(),
          map(),
          term(),
          ReqManagedAgents.SessionInfo.t(),
          map()
        ) :: map()
  def run(handler, id, name, input, context, info, meta \\ %{}) do
    :telemetry.span([:req_managed_agents, :tool], Map.merge(meta, %{tool: name}), fn ->
      event = do_run(handler, id, name, input, context, info)
      {event, Map.merge(meta, %{tool: name, is_error: event["is_error"] == true})}
    end)
  end

  defp do_run(handler, id, name, input, context, info) do
    result =
      cond do
        is_function(handler, 4) ->
          handler.(name, input, context, info)

        is_function(handler, 3) ->
          handler.(name, input, context)

        exports?(handler, :handle_tool_call, 4) ->
          handler.handle_tool_call(name, input, context, info)

        true ->
          handler.handle_tool_call(name, input, context)
      end

    case result do
      {:ok, text} -> Event.custom_tool_result(id, to_string(text))
      {:error, text} -> Event.custom_tool_result(id, to_string(text), is_error: true)
    end
  catch
    kind, reason ->
      Event.custom_tool_result(id, "tool #{kind}: #{inspect(reason)}", is_error: true)
  end

  # ensure_loaded first: a handler that exports ONLY the 4-arity form may not be
  # loaded when its first tool call arrives (function_exported?/3 alone would
  # miss it and misroute to the 3-arity call).
  defp exports?(mod, fun, arity),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
end
