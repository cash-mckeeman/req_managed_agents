defmodule ReqManagedAgents.SessionResult do
  @moduledoc """
  The accumulated outcome of a whole run — what `Session.run/2` and `message/2` deliver.

  `transcript` is the provider's client-held history when the provider exports
  `transcript/1` (potentially large); `nil` for server-held providers.

  `in_flight: :unknown` means additional provider work may be unmeasured;
  `:none` marks a completed local boundary. `usage.complete?` describes the
  represented contributions, so neither flag alone certifies total billed cost.

  `outcomes` is the provider's native grading evidence projected from `events`
  (`[]` when the provider has none). It resets with `Session.message/2` and
  accumulates across `Session.send_event/2` chained definitions, in
  first-observation order, so `hd/1` is not the current outcome: select by
  `outcome_id`. A grade is not a completion signal; read `terminal` for that.
  """
  @derive Jason.Encoder
  defstruct terminal: :terminated,
            stop_reason: nil,
            in_flight: :unknown,
            session_id: nil,
            text: "",
            custom_tool_uses: [],
            server_tool_uses: [],
            usage: %ReqManagedAgents.Usage{},
            turns: 0,
            events: [],
            outcomes: [],
            transcript: nil

  @type t :: %__MODULE__{
          terminal: ReqManagedAgents.Provider.terminal(),
          in_flight: :none | :unknown,
          stop_reason: String.t() | map() | atom() | nil,
          session_id: String.t() | nil,
          text: String.t(),
          custom_tool_uses: [ReqManagedAgents.ToolUse.t()],
          server_tool_uses: [ReqManagedAgents.ToolUse.t()],
          usage: ReqManagedAgents.Usage.t(),
          turns: non_neg_integer(),
          events: [map()],
          outcomes: [ReqManagedAgents.OutcomeResult.t()],
          transcript: [map()] | nil
        }
end
