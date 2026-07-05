defmodule ReqManagedAgents.Event do
  @moduledoc """
  Outbound event builders and inbound event classification for Managed Agents.

  Events are plain JSON maps with string keys (the wire shape). Builders produce
  events to POST to `/v1/sessions/{id}/events`; `classify/1` reduces an inbound
  event to a terminal/flow atom for loop control.
  """

  @type event :: %{required(String.t()) => term()}
  @type terminal ::
          :end_turn
          | :requires_action
          | :retries_exhausted
          | :terminated
          | :error
          | :unknown_idle
          | :other

  @doc "Build a `user.message` text event."
  @spec user_message(String.t()) :: event()
  def user_message(text) when is_binary(text) do
    %{"type" => "user.message", "content" => [%{"type" => "text", "text" => text}]}
  end

  @doc "Build a `user.define_outcome` event. `rubric_md` is inline markdown criteria."
  @spec define_outcome(String.t(), String.t(), keyword()) :: event()
  def define_outcome(description, rubric_md, opts \\ [])
      when is_binary(description) and is_binary(rubric_md) do
    base = %{
      "type" => "user.define_outcome",
      "description" => description,
      "rubric" => %{"type" => "text", "content" => rubric_md}
    }

    # A nil from a caller's absent map key (e.g. kickoff_input's o[:max_iterations])
    # must not become "max_iterations" => nil on the wire.
    case Keyword.fetch(opts, :max_iterations) do
      {:ok, n} when is_integer(n) -> Map.put(base, "max_iterations", n)
      _ -> base
    end
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

  @doc "Classify an inbound event into a flow-control atom."
  @spec classify(event()) :: terminal()
  def classify(%{"type" => "session.status_idle", "stop_reason" => %{"type" => reason}}) do
    case reason do
      "end_turn" -> :end_turn
      "requires_action" -> :requires_action
      "retries_exhausted" -> :retries_exhausted
      "satisfied" -> :end_turn
      "max_iterations_reached" -> :end_turn
      "failed" -> :terminated
      _ -> :unknown_idle
    end
  end

  def classify(%{"type" => "session.status_terminated"}), do: :terminated
  def classify(%{"type" => "session.error"}), do: :error
  def classify(_), do: :other
end
