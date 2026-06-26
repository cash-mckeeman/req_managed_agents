defmodule ReqManagedAgents.Tools do
  @moduledoc false
  # Shared local-tool execution for Session and run_to_completion. Always returns
  # a `user.custom_tool_result` event; any failure becomes an `is_error` result so
  # the session never hangs.
  alias ReqManagedAgents.Event

  @spec run(module(), String.t(), String.t(), map(), term()) :: map()
  def run(handler, id, name, input, context) do
    try do
      case handler.handle_tool_call(name, input, context) do
        {:ok, text} -> Event.custom_tool_result(id, to_string(text))
        {:error, text} -> Event.custom_tool_result(id, to_string(text), is_error: true)
      end
    catch
      kind, reason ->
        Event.custom_tool_result(id, "tool #{kind}: #{inspect(reason)}", is_error: true)
    end
  end
end
