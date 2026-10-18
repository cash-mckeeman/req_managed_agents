defmodule ReqManagedAgents.Test.FailureProvider do
  @moduledoc false
  @behaviour ReqManagedAgents.Provider
  alias ReqManagedAgents.{ToolUse, TurnResult, Usage}

  @impl true
  def mode, do: :request_response
  @impl true
  def provision(_spec, _opts), do: {:error, :not_implemented}
  @impl true
  def open(opts, subscriber) do
    if opts[:test_pid], do: send(opts[:test_pid], {:opened, self()})
    result = if opts[:open_fun], do: opts[:open_fun].(opts), else: :ok

    with :ok <- result do
      ref = make_ref()
      consumer = if opts[:consumer_fun], do: opts[:consumer_fun].(subscriber, ref)
      if opts[:streaming], do: send(subscriber, {:managed_agents, ref, :connected})
      {:ok, %{opts: opts, subscriber: subscriber, ref: ref, index: 0, consumer: consumer}}
    end
  end

  @impl true
  def kickoff_input(_opts), do: :kickoff
  @impl true
  def user_input(text), do: {:user, text}
  @impl true
  def resume_input(_uses, results), do: {:resume, results}
  @impl true
  def poll_turn(conn, input) do
    case conn.opts[:poll_fun].(conn.index, input) do
      {:ok, events} -> {:ok, events, %{conn | index: conn.index + 1}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def push_input(conn, input), do: conn.opts[:push_fun].(conn.subscriber, conn.ref, input)
  @impl true
  def turn_boundary?(event), do: event["type"] == "turn"
  @impl true
  def normalize(events) do
    event = Enum.find(events, &(&1["type"] == "turn"))
    {:ok, usage} = Usage.new(event["usage"])
    tools = if event["tool"], do: [%ToolUse{id: "tool", name: "echo", input: %{}}], else: []

    %TurnResult{
      terminal: event["terminal"],
      stop_reason: event["stop_reason"],
      text: event["text"] || "",
      custom_tool_uses: tools,
      usage: usage,
      events: events
    }
  end

  @impl true
  def session_id(_conn), do: "same-session"
  @impl true
  def ref(conn), do: conn.ref
  @impl true
  def consumer(conn), do: conn.consumer
  @impl true
  def resumed?(_conn), do: false
  @impl true
  def transcript(conn) do
    if conn.opts[:transcript_fun],
      do: conn.opts[:transcript_fun].(conn),
      else: [%{"role" => "assistant", "content" => to_string(conn.index)}]
  end

  defmodule Streaming do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    alias ReqManagedAgents.Test.FailureProvider
    @impl true
    def mode, do: :streaming
    @impl true
    defdelegate provision(spec, opts), to: FailureProvider
    @impl true
    def open(opts, subscriber),
      do:
        FailureProvider.open(
          Keyword.put(opts, :streaming, true),
          subscriber
        )

    @impl true
    def reconnect_with_events(conn, subscriber, seen) do
      if conn.opts[:reconnect_fun],
        do: conn.opts[:reconnect_fun].(conn, subscriber, seen),
        else: {:ok, conn, [], seen, []}
    end

    @impl true
    defdelegate kickoff_input(opts), to: FailureProvider
    @impl true
    defdelegate user_input(text), to: FailureProvider
    @impl true
    defdelegate resume_input(uses, results), to: FailureProvider
    @impl true
    defdelegate push_input(conn, input), to: FailureProvider
    @impl true
    defdelegate turn_boundary?(event), to: FailureProvider
    @impl true
    defdelegate normalize(events), to: FailureProvider
    @impl true
    defdelegate session_id(conn), to: FailureProvider
    @impl true
    defdelegate ref(conn), to: FailureProvider
    @impl true
    defdelegate consumer(conn), to: FailureProvider
    @impl true
    defdelegate resumed?(conn), to: FailureProvider
  end
end
