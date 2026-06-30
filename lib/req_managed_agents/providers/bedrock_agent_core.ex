defmodule ReqManagedAgents.Providers.BedrockAgentCore do
  @moduledoc """
  `ReqManagedAgents.Provider` implementation for the Bedrock AgentCore (`vnd.amazon.eventstream`)
  backend. A thin adapter over the existing `AgentCore.EventStream` and `AgentCore.Converse`.

  `Converse.parse/1` only surfaces `toolUse` content blocks at `stopReason: "tool_use"` —
  these are the return-of-control `inline_function` calls (client-side by construction).
  Harness-executed built-in tools do not produce a `tool_use` stop and never appear here.
  """
  @behaviour ReqManagedAgents.Provider

  alias ReqManagedAgents.AgentCore.{Converse, EventStream}

  @impl true
  def decode(buffer), do: EventStream.decode(buffer)

  @impl true
  def normalize(events) do
    %{stop_reason: reason, tool_uses: tool_uses, text: text} = Converse.parse(events)

    custom_tool_uses =
      Enum.map(tool_uses, fn %{"toolUseId" => id, "name" => name, "input" => input} ->
        %{id: id, name: name, input: input}
      end)

    %{terminal: terminal(reason), stop_reason: reason, custom_tool_uses: custom_tool_uses, text: text}
  end

  @impl true
  def terminal("end_turn"), do: :end_turn
  def terminal("stop_sequence"), do: :end_turn
  def terminal("tool_use"), do: :requires_action
  def terminal(_other), do: :terminated

  @impl true
  def resume(custom_tool_uses, results) do
    wire =
      Enum.map(custom_tool_uses, fn %{id: id, name: name, input: input} ->
        %{"toolUseId" => id, "name" => name, "input" => input}
      end)

    Converse.resume_messages(wire, results)
  end
end
