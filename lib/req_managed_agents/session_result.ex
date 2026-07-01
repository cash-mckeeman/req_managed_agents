defmodule ReqManagedAgents.SessionResult do
  @moduledoc "The accumulated outcome of a whole run — what `Session.run/2` and `message/2` deliver."
  @derive Jason.Encoder
  defstruct terminal: :terminated,
            stop_reason: nil,
            text: "",
            custom_tool_uses: [],
            server_tool_uses: [],
            usage: %ReqManagedAgents.Usage{},
            turns: 0,
            events: []

  @type t :: %__MODULE__{
          terminal: ReqManagedAgents.Provider.terminal(),
          stop_reason: String.t() | map() | nil,
          text: String.t(),
          custom_tool_uses: [ReqManagedAgents.ToolUse.t()],
          server_tool_uses: [ReqManagedAgents.ToolUse.t()],
          usage: ReqManagedAgents.Usage.t(),
          turns: non_neg_integer(),
          events: [map()]
        }
end
