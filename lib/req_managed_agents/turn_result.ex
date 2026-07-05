defmodule ReqManagedAgents.TurnResult do
  @moduledoc "The canonical outcome of ONE turn — what `Provider.normalize/1` returns."
  @derive Jason.Encoder
  defstruct terminal: :terminated,
            stop_reason: nil,
            text: "",
            custom_tool_uses: [],
            server_tool_uses: [],
            usage: nil,
            events: []

  @type t :: %__MODULE__{
          terminal: ReqManagedAgents.Provider.terminal(),
          stop_reason: String.t() | map() | atom() | nil,
          text: String.t(),
          custom_tool_uses: [ReqManagedAgents.ToolUse.t()],
          server_tool_uses: [ReqManagedAgents.ToolUse.t()],
          usage: ReqManagedAgents.Usage.t() | nil,
          events: [map()]
        }
end
