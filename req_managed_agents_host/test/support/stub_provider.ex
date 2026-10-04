defmodule StubProvider do
  @moduledoc """
  Minimal `:request_response` `ReqManagedAgents.Provider` for `SessionServer` tests. `open/2`
  mints a session id unless `opts[:session_id]` is given, in which case it reuses it and marks
  the conn `resume: true` — `resumed?/1` echoes that flag, which drives `Session` down the
  reattach path (`handle_continue(:resume, …)` → `reconnect/3` → the resume's pending
  `:prompt` is delivered via `user_input/1` — the same seam a live follow-up uses). Every turn
  is a single no-tool `:end_turn`. Every `open/2` session id and every delivered message
  (kickoff or reattach) is recorded on an owned `Agent`, read back via `opened_with/0` /
  `delivered_messages/0`.
  """
  @behaviour ReqManagedAgents.Provider

  alias ReqManagedAgents.TurnResult

  @recorder __MODULE__.Recorder

  @impl true
  def mode, do: :request_response

  @impl true
  def provision(spec, _opts), do: {:ok, spec}

  @impl true
  def teardown(_handle, _opts), do: :ok

  @impl true
  def open(opts, _subscriber) do
    sid = opts[:session_id] || "sess-#{System.unique_integer([:positive])}"
    record(:opened_with, sid)
    record(:opened_timeout, opts[:timeout])
    {:ok, %{session_id: sid, resume: opts[:session_id] != nil}}
  end

  @impl true
  def session_id(conn), do: conn.session_id

  @impl true
  def ref(_conn), do: nil

  @impl true
  def consumer(_conn), do: nil

  @impl true
  def resumed?(conn), do: conn.resume

  # Optional per the behaviour (:streaming-only per its doc), but `Session`'s reattach seam
  # (#66) calls it unconditionally on `resumed?/1 == true` regardless of mode — a
  # request_response provider whose `resumed?/1` can be true MUST still implement it, or the
  # reattach path dies with `:undef`. Nothing to consolidate here: no pending tool uses, the
  # conn is already live.
  @impl true
  def reconnect(conn, _subscriber, seen), do: {:ok, conn, [], seen}

  @impl true
  def kickoff_input(opts) do
    text = opts[:prompt] || ""
    record(:delivered, text)
    {:text, text}
  end

  @impl true
  def user_input(text) do
    record(:delivered, text)
    {:text, text}
  end

  @impl true
  def resume_input(_tool_uses, _results), do: {:text, ""}

  @impl true
  def poll_turn(conn, _input), do: {:ok, [%{"type" => "stub.end_turn"}], conn}

  @impl true
  def normalize(events),
    do: %TurnResult{terminal: :end_turn, stop_reason: "stop", text: "", events: events}

  @impl true
  def text_delta(_event), do: nil

  @doc "Session ids `open/2` has seen, oldest first."
  @spec opened_with() :: [String.t()]
  def opened_with, do: ensure_recorder() |> Agent.get(& &1.opened_with) |> Enum.reverse()

  @doc "User-facing texts delivered via `kickoff_input/1` or `user_input/1`, oldest first."
  @spec delivered_messages() :: [String.t()]
  def delivered_messages, do: ensure_recorder() |> Agent.get(& &1.delivered) |> Enum.reverse()

  @doc "`:timeout` opts `open/2` has seen, oldest first (nil where the caller omitted it)."
  @spec opened_timeouts() :: [term()]
  def opened_timeouts, do: ensure_recorder() |> Agent.get(& &1.opened_timeout) |> Enum.reverse()

  defp record(key, value) do
    recorder = ensure_recorder()
    Agent.update(recorder, &Map.update!(&1, key, fn list -> [value | list] end))
  end

  defp ensure_recorder do
    case Agent.start(fn -> %{opened_with: [], delivered: [], opened_timeout: []} end,
           name: @recorder
         ) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
