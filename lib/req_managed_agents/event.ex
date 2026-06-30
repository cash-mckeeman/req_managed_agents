defmodule ReqManagedAgents.Event do
  @moduledoc """
  Outbound event builders for Managed Agents.

  Events are plain JSON maps with string keys (the wire shape). Builders produce
  events to POST to `/v1/sessions/{id}/events`. Inbound event classification now
  lives with its consumers: `ReqManagedAgents.Provider.terminal/1` for the canonical
  3-atom taxonomy the providers use, and `ReqManagedAgents.Profile.terminal?/3` for
  jido wire-compat.
  """

  @type event :: %{required(String.t()) => term()}

  @doc "Build a `user.message` text event."
  @spec user_message(String.t()) :: event()
  def user_message(text) when is_binary(text) do
    %{"type" => "user.message", "content" => [%{"type" => "text", "text" => text}]}
  end

  @doc "Build a `user.custom_tool_result` event. Pass `is_error: true` for failures."
  @spec custom_tool_result(String.t(), String.t(), keyword()) :: event()
  def custom_tool_result(custom_tool_use_id, text, opts \\ []) do
    %{
      "type" => "user.custom_tool_result",
      "custom_tool_use_id" => custom_tool_use_id,
      "content" => [%{"type" => "text", "text" => text}],
      "is_error" => Keyword.get(opts, :is_error, false)
    }
  end

  @doc "Build a `user.tool_confirmation` event (`:allow` or `:deny`)."
  @spec tool_confirmation(String.t(), :allow | :deny) :: event()
  def tool_confirmation(tool_use_id, decision) when decision in [:allow, :deny] do
    %{
      "type" => "user.tool_confirmation",
      "tool_use_id" => tool_use_id,
      "result" => Atom.to_string(decision)
    }
  end
end
