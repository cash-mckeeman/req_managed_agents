defmodule StubLocalProvider do
  @moduledoc """
  Minimal `:request_response` `ReqManagedAgents.Provider` for transcript-persistence tests —
  a `Local`-shaped provider whose conversation history lives in the `conn` (as opposed to
  `StubProvider`, which models a server-held provider with no `transcript/1`). `open/2` seeds
  `conn.history` from `opts[:history]` when given (a resume) or starts empty; `resumed?/1`
  echoes whether a history was supplied. Every `poll_turn/2` appends the delivered user text
  and a canned assistant reply to `conn.history` — so `transcript/1` grows by two entries per
  turn, like a real one-turn chat. Every `open/2` session id + history pair is recorded on an
  owned `Agent`, read back via `opened_with/0`.

  That `Agent` is a single process registered under a module-global name (`__MODULE__.Recorder`),
  shared by every test in the suite that uses this stub. Under `async: true`, calls from
  unrelated test modules can interleave with your own — `opened_with/0` returns entries from
  all of them in call order, not just yours. Filter by a value unique to your call (e.g. the
  `session_id`) rather than assuming your entries are the only or the last ones.
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

  # Client-held history: open seeds from opts[:history] (resume) or starts fresh;
  # each completed run's transcript is history + [user, assistant].
  @impl true
  def open(opts, _subscriber) do
    record(:opened_with, {opts[:session_id], opts[:history]})
    history = opts[:history] || []

    {:ok,
     %{
       history: history,
       resume: opts[:history] != nil,
       session_id:
         opts[:session_id] ||
           "stub-local-" <> Integer.to_string(:erlang.unique_integer([:positive]))
     }}
  end

  @impl true
  def session_id(conn), do: conn.session_id

  @impl true
  def ref(_conn), do: nil

  @impl true
  def consumer(_conn), do: nil

  @impl true
  def resumed?(conn), do: conn.resume

  @impl true
  def transcript(conn), do: conn.history

  @impl true
  def kickoff_input(opts) do
    text = opts[:prompt] || ""
    {:text, text}
  end

  @impl true
  def user_input(text), do: {:text, text}

  @impl true
  def resume_input(_tool_uses, _results), do: {:text, ""}

  # poll_turn appends the user message + a canned assistant reply into history,
  # then stops — so transcript grows by 2 per run, like a real one-turn chat.
  @impl true
  def poll_turn(conn, {:text, text}) do
    grown =
      conn.history ++
        [
          %{"role" => "user", "content" => text},
          %{"role" => "assistant", "content" => "ack: " <> text}
        ]

    {:ok, [%{"type" => "stub_local.end_turn"}], %{conn | history: grown}}
  end

  @impl true
  def normalize(events),
    do: %TurnResult{terminal: :end_turn, stop_reason: "stop", text: "", events: events}

  @impl true
  def text_delta(_event), do: nil

  @doc "`{session_id, history}` pairs `open/2` has seen, oldest first."
  @spec opened_with() :: [{String.t() | nil, [map()] | nil}]
  def opened_with, do: ensure_recorder() |> Agent.get(& &1.opened_with) |> Enum.reverse()

  defp record(key, value) do
    recorder = ensure_recorder()
    Agent.update(recorder, &Map.update!(&1, key, fn list -> [value | list] end))
  end

  defp ensure_recorder do
    case Agent.start(fn -> %{opened_with: []} end, name: @recorder) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
