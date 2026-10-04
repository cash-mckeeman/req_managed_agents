defmodule EchoHandler do
  @moduledoc "Minimal `ReqManagedAgents.Handler` for no-tool-call test sessions: echoes any tool input back as its own text."
  @behaviour ReqManagedAgents.Handler

  @impl true
  def handle_tool_call(_name, input, _ctx), do: {:ok, inspect(input)}

  @impl true
  def handle_event(_event, _ctx), do: :ok
end
