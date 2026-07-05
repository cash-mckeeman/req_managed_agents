defmodule ReqManagedAgents.Local.Directives do
  @moduledoc false
  # Loop directives injected into the conversation for weak-instruction-following
  # local models. Wording relocated verbatim from biai-managed-agents
  # Core.Runner.Directives (eval-gate continuity), except final_turn/1 which
  # names the spec's terminal_tool instead of biai's hardcoded example.

  def duplicate_tool,
    do:
      "You already called this tool with these exact arguments; the result is unchanged. " <>
        "Do NOT repeat it. If you have enough information, call your terminal tool now."

  def final_turn(nil),
    do:
      "FINAL TURN: you are about to reach the maximum number of turns. You MUST produce " <>
        "your final answer now with the information you have already gathered. Do not " <>
        "call any other tool."

  def final_turn(terminal_tool),
    do:
      "FINAL TURN: you are about to reach the maximum number of turns. You MUST call " <>
        "your terminal tool (#{terminal_tool}) now with the information you have already " <>
        "gathered. Do not call any other tool."

  def corrective(name, err),
    do:
      "STOP — the #{name} tool rejected your input again: #{err}. You must change your input to " <>
        "fix THIS specific error before calling #{name} again (or call your terminal tool)."
end
