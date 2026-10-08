defmodule ReqManagedAgents.Tools do
  @moduledoc false
  alias ReqManagedAgents.Evidence.Recorder
  alias ReqManagedAgents.ToolResult

  @type handler_fun ::
          (String.t(), map(), term() -> {:ok, String.t()} | {:error, String.t()})
          | (String.t(), map(), term(), ReqManagedAgents.SessionInfo.t() ->
               {:ok, String.t()} | {:error, String.t()})

  @spec execute(
          module() | handler_fun(),
          String.t(),
          String.t(),
          map(),
          term(),
          ReqManagedAgents.SessionInfo.t(),
          map(),
          Recorder.Context.t() | nil
        ) :: ToolResult.t()
  def execute(handler, id, name, input, context, info, meta \\ %{}, evidence \\ nil) do
    Recorder.observe(evidence, :tool_start, tool_use_id: id)

    :telemetry.span([:req_managed_agents, :tool], Map.merge(meta, %{tool: name}), fn ->
      result = do_run(handler, id, name, input, context, info)

      fields =
        if result.is_error, do: [result: :error, error_code: "tool_error"], else: [result: :ok]

      Recorder.observe(evidence, :tool_end, [tool_use_id: id] ++ fields)
      {result, Map.merge(meta, %{tool: name, is_error: result.is_error})}
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
      {:ok, text} -> %ToolResult{tool_use_id: id, text: to_string(text)}
      {:error, text} -> %ToolResult{tool_use_id: id, text: to_string(text), is_error: true}
    end
  catch
    kind, reason ->
      %ToolResult{tool_use_id: id, text: "tool #{kind}: #{inspect(reason)}", is_error: true}
  end

  # ensure_loaded first: a handler that exports ONLY the 4-arity form may not be
  # loaded when its first tool call arrives (function_exported?/3 alone would
  # miss it and misroute to the 3-arity call).
  defp exports?(mod, fun, arity),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
end
